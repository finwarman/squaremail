use crate::{Result, network::Context};
use quick_xml::{Reader, XmlVersion, events::Event};
use std::{collections::HashSet, fs::File, io::Read, path::Path};

pub(super) const DOCX: &str =
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document";
pub(super) const XLSX: &str = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
const ENTRY_LIMIT: usize = 2048;
const EXPANDED_LIMIT: u64 = 32 * 1024 * 1024;
const RELATION_LIMIT: u64 = 256 * 1024;
enum XmlKind {
    Relationships,
    Document,
}

pub(super) fn validate(path: &Path, mime: &str, context: &Context<'_>) -> Result<()> {
    if mime != DOCX && mime != XLSX {
        return Ok(());
    }
    let mut archive = zip::ZipArchive::new(File::open(path)?)?;
    if archive.len() > ENTRY_LIMIT {
        return Err("Office package contains too many entries".into());
    }
    let mut names = HashSet::new();
    let mut total = 0_u64;
    let mut buffer = [0_u8; 64 * 1024];
    for index in 0..archive.len() {
        context.check()?;
        let mut file = archive.by_index(index)?;
        let name = file.name()?.to_lowercase();
        if file.enclosed_name().is_none()
            || file.encrypted()
            || !names.insert(name.clone())
            || name.contains("vbaproject")
            || name.contains("/embeddings/")
        {
            return Err(
                "Encrypted, macro-enabled or embedded-object Office previews are blocked".into(),
            );
        }
        if file.size() > EXPANDED_LIMIT.saturating_sub(total) {
            return Err("Office package exceeds the 32 MiB expansion limit".into());
        }
        if name.ends_with(".rels") || name.ends_with(".xml") {
            let kind = if name.ends_with(".rels") {
                XmlKind::Relationships
            } else {
                XmlKind::Document
            };
            let limit = match kind {
                XmlKind::Relationships => RELATION_LIMIT,
                XmlKind::Document => EXPANDED_LIMIT.saturating_sub(total),
            };
            if file.size() > limit {
                return Err("Office relationships exceed the preview limit".into());
            }
            let mut bytes = Vec::new();
            file.take(limit + 1).read_to_end(&mut bytes)?;
            if bytes.len() as u64 > limit {
                return Err("Office relationships exceed the preview limit".into());
            }
            total += bytes.len() as u64;
            inspect_xml(&bytes, kind)?;
        } else {
            loop {
                context.check()?;
                let count = file.read(&mut buffer)?;
                if count == 0 {
                    break;
                }
                total = total.saturating_add(count as u64);
                if total > EXPANDED_LIMIT {
                    return Err("Office package exceeds the 32 MiB expansion limit".into());
                }
            }
        }
    }
    let required = if mime == DOCX {
        "word/document.xml"
    } else {
        "xl/workbook.xml"
    };
    if !names.contains("[content_types].xml") || !names.contains(required) {
        return Err("Office package is missing its document".into());
    }
    Ok(())
}

fn inspect_xml(bytes: &[u8], kind: XmlKind) -> Result<()> {
    let mut reader = Reader::from_reader(bytes);
    let mut version = XmlVersion::Implicit1_0;
    loop {
        match reader.read_event()? {
            Event::Start(node) | Event::Empty(node) => {
                if matches!(kind, XmlKind::Document) {
                    continue;
                }
                for attribute in node.attributes() {
                    let attribute = attribute?;
                    let name = attribute.key.local_name();
                    let value = attribute.normalized_value(version)?.to_lowercase();
                    if (name.as_ref() == "TargetMode" && value == "external")
                        || (name.as_ref() == "Target" && value.contains(':'))
                    {
                        return Err(
                            "Office files with external relationships are blocked in this preview"
                                .into(),
                        );
                    }
                }
            }
            Event::DocType(_) => return Err("Office XML document types are blocked".into()),
            Event::Decl(declaration) => version = declaration.xml_version()?,
            Event::Eof => break,
            _ => {}
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Cursor, Write};

    fn package(files: &[(&str, &[u8])]) -> Vec<u8> {
        let mut writer = zip::ZipWriter::new(Cursor::new(Vec::new()));
        for (name, bytes) in files {
            writer
                .start_file(*name, zip::write::SimpleFileOptions::default())
                .unwrap();
            writer.write_all(bytes).unwrap();
        }
        writer.finish().unwrap().into_inner()
    }

    #[test]
    fn office_package_limits() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sample.docx");
        let context = Context::new(None, 10);
        let base = [
            ("[Content_Types].xml", b"<Types/>".as_slice()),
            ("word/document.xml", b"<document/>".as_slice()),
        ];
        std::fs::write(&path, package(&base)).unwrap();
        validate(&path, DOCX, &context).unwrap();
        let mut files = base.to_vec();
        files.push(("word/vbaProject.bin", b"macro"));
        std::fs::write(&path, package(&files)).unwrap();
        assert!(validate(&path, DOCX, &context).is_err());
        files.pop();
        files.push((
            "word/_rels/document.xml.rels",
            b"<Relationship TargetMode='External' Target='https://tracker.example/x'/>",
        ));
        std::fs::write(&path, package(&files)).unwrap();
        assert!(validate(&path, DOCX, &context).is_err());

        let mut writer = zip::ZipWriter::new(Cursor::new(Vec::new()));
        writer
            .start_file(
                "word/document.xml",
                zip::write::SimpleFileOptions::default()
                    .compression_method(zip::CompressionMethod::Deflated),
            )
            .unwrap();
        std::io::copy(
            &mut std::io::repeat(b'x').take(EXPANDED_LIMIT + 1),
            &mut writer,
        )
        .unwrap();
        std::fs::write(&path, writer.finish().unwrap().into_inner()).unwrap();
        assert!(validate(&path, DOCX, &context).is_err());
    }

    #[test]
    fn external_relationships_blocked() {
        assert!(
            inspect_xml(
                b"<Relationships><Relationship Target='media/image.png'/></Relationships>",
                XmlKind::Relationships
            )
            .is_ok()
        );
        for xml in [
            "<Relationship TargetMode='External' Target='https://tracker.example/x'/>",
            "<Relationship Target='https&#58;//tracker.example/x'/>",
            "<!DOCTYPE x><Relationships/>",
        ] {
            assert!(inspect_xml(xml.as_bytes(), XmlKind::Relationships).is_err());
        }
        assert!(inspect_xml(b"<!DOCTYPE x><document/>", XmlKind::Document).is_err());
    }
}
