use super::*;
use std::collections::BTreeSet;
use unicode_normalization::{UnicodeNormalization, char::is_combining_mark};

#[cfg(test)]
mod tests;

pub(super) const INDEX_VERSION: i64 = 5;
const QUERY_BYTES: usize = 1024;
const QUERY_PARTS: usize = 12;
const FUZZY_WORDS: usize = 6;
const WORD_MIN: usize = 4;
const WORD_MAX: usize = 32;
const CANDIDATE_LIMIT: usize = 2048;
const MATCH_LIMIT: usize = 8;
const EXPANSION_LIMIT: usize = 24;

pub(super) fn register(connection: &Connection) -> Result<()> {
    use rusqlite::functions::FunctionFlags;
    connection.create_scalar_function(
        "squaremail_header_text",
        1,
        FunctionFlags::SQLITE_UTF8
            | FunctionFlags::SQLITE_DETERMINISTIC
            | FunctionFlags::SQLITE_INNOCUOUS,
        |ctx| {
            let raw = ctx.get_raw(0).as_str()?;
            Ok(crate::header_text::decode(raw).into_owned())
        },
    )?;
    Ok(())
}

fn has_token(part: &str) -> bool {
    part.chars().any(|c| {
        c.is_alphanumeric()
            || matches!(c as u32, 0xe000..=0xf8ff | 0xf0000..=0xffffd | 0x100000..=0x10fffd)
    })
}

pub(super) fn literal(query: &str) -> Result<String> {
    if query.len() > QUERY_BYTES || query.split_whitespace().count() > QUERY_PARTS {
        return Err("Search supports up to 12 words and 1 KiB of text".into());
    }
    let terms = query
        .split_whitespace()
        .filter(|part| has_token(part))
        .map(quoted)
        .collect::<Vec<_>>()
        .join(" AND ");
    // A punctuation-only query must not become the unfiltered mailbox.
    if terms.is_empty() && !query.trim().is_empty() {
        return Ok("\"\"".into());
    }
    Ok(terms)
}

fn quoted(term: &str) -> String {
    format!("\"{}\"*", term.replace('"', "\"\""))
}

impl Store {
    pub(crate) fn search_folder(
        &self,
        scope: MailScope<'_>,
        query: &str,
        mode: SearchMode,
        offset: usize,
        limit: usize,
    ) -> Result<SearchPage> {
        let tx = self.connection.unchecked_transaction()?;
        let result = self.search_inner(scope, query, mode, offset, limit)?;
        tx.commit()?;
        Ok(result)
    }

    fn search_inner(
        &self,
        scope: MailScope<'_>,
        query: &str,
        mode: SearchMode,
        offset: usize,
        limit: usize,
    ) -> Result<SearchPage> {
        let terms = literal(query)?;
        let messages = self.match_rows(
            scope.account,
            scope.folder,
            scope.remote,
            &terms,
            offset,
            limit,
        )?;
        let has_literal = !messages.is_empty()
            || (offset > 0
                && !self
                    .match_rows(scope.account, scope.folder, scope.remote, &terms, 0, 1)?
                    .is_empty());
        if has_literal || terms.is_empty() || mode == SearchMode::Literal || limit == 0 {
            return Ok(SearchPage {
                kind: if has_literal {
                    SearchMatch::Literal
                } else {
                    SearchMatch::None
                },
                messages,
            });
        }
        let Some(expanded) = self.fuzzy_terms(query)? else {
            return Ok(SearchPage {
                messages,
                kind: SearchMatch::None,
            });
        };
        let messages = self.match_rows(
            scope.account,
            scope.folder,
            scope.remote,
            &expanded,
            offset,
            limit,
        )?;
        let kind = if messages.is_empty() && offset == 0 {
            SearchMatch::None
        } else {
            SearchMatch::Approximate
        };
        Ok(SearchPage { messages, kind })
    }

    fn fuzzy_terms(&self, query: &str) -> Result<Option<String>> {
        let mut remaining = FUZZY_WORDS;
        let mut changed = false;
        let mut groups = Vec::new();
        for part in query.split_whitespace().filter(|part| has_token(part)) {
            let normalized: String = part
                .nfd()
                .filter(|c| !is_combining_mark(*c))
                .flat_map(char::to_lowercase)
                .collect();
            let mut alternatives = BTreeSet::new();
            alternatives.insert(quoted(part));
            for (start, end) in word_ranges(&normalized) {
                if remaining == 0 || alternatives.len() >= EXPANSION_LIMIT {
                    break;
                }
                let word = &normalized[start..end];
                let length = word.chars().count();
                if !(WORD_MIN..=WORD_MAX).contains(&length)
                    || !word.chars().all(char::is_alphabetic)
                {
                    continue;
                }
                remaining -= 1;
                for correction in self.nearby_words(word)? {
                    if alternatives.len() >= EXPANSION_LIMIT {
                        break;
                    }
                    let corrected = format!(
                        "{}{}{}",
                        &normalized[..start],
                        correction,
                        &normalized[end..]
                    );
                    changed |= alternatives.insert(quoted(&corrected));
                }
            }
            groups.push(format!(
                "({})",
                alternatives.into_iter().collect::<Vec<_>>().join(" OR ")
            ));
        }
        Ok(changed.then(|| groups.join(" AND ")))
    }

    fn nearby_words(&self, word: &str) -> Result<Vec<String>> {
        let candidates = edits(word);
        if candidates.is_empty() {
            return Ok(Vec::new());
        }
        // FTS5 vocab equality probes seek dictionary terms, without scanning mail bodies.
        let placeholders = vec!["?"; candidates.len()].join(",");
        let sql = format!(
            "SELECT term FROM message_vocabulary WHERE term IN({placeholders}) ORDER BY term LIMIT {MATCH_LIMIT}"
        );
        let mut statement = self.connection.prepare(&sql)?;
        Ok(statement
            .query_map(rusqlite::params_from_iter(candidates), |row| row.get(0))?
            .collect::<rusqlite::Result<_>>()?)
    }
}

fn word_ranges(text: &str) -> Vec<(usize, usize)> {
    let mut result = Vec::new();
    let mut start = None;
    for (index, character) in text
        .char_indices()
        .chain(std::iter::once((text.len(), ' ')))
    {
        if character.is_alphanumeric() {
            start.get_or_insert(index);
        } else if let Some(begin) = start.take() {
            result.push((begin, index));
        }
    }
    result
}

fn edits(word: &str) -> Vec<String> {
    let chars: Vec<char> = word.chars().collect();
    let mut values = BTreeSet::new();
    for index in 0..=chars.len() {
        if index < chars.len() {
            let mut value = chars.clone();
            value.remove(index);
            values.insert(value.iter().collect::<String>());
            if index + 1 < chars.len() {
                let mut value = chars.clone();
                value.swap(index, index + 1);
                values.insert(value.iter().collect::<String>());
            }
        }
        for letter in 'a'..='z' {
            let mut value = chars.clone();
            value.insert(index, letter);
            values.insert(value.iter().collect::<String>());
            if index < chars.len() {
                let mut value = chars.clone();
                value[index] = letter;
                values.insert(value.iter().collect::<String>());
            }
        }
    }
    values.remove(word);
    values.into_iter().take(CANDIDATE_LIMIT).collect()
}
