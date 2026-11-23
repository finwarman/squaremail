use super::*;
fn finish(database: &str) {
    for _ in 0..1000 {
        if step(database, &network::Context::new(None, 25))
            .unwrap()
            .pending
            == 0
        {
            return;
        }
    }
    panic!("Index did not complete bounded work");
}
#[test]
fn offline_bodies_and_revisions() {
    let folder = tempfile::tempdir().unwrap();
    let path = folder.path().join("mail.sqlite");
    let database = path.to_str().unwrap();
    let note = super::super::new(database, Some("2026-11-23")).unwrap();
    let text = format!(
        "# Monday\n{}\nCafé O'Reilly planning needledeep",
        "ordinary ".repeat(1000)
    );
    let saved = super::super::save(database, &note.id, &text, Some(&note.revision)).unwrap();
    assert_eq!(list(database).unwrap().pending, 1);
    finish(database);
    assert_eq!(
        search(database, "cafe reilly needledeep").unwrap().notes[0].id,
        note.id
    );
    assert_eq!(search(database, "2026-11-23").unwrap().notes.len(), 1);
    assert!(
        search(database, "needledeep OR absent")
            .unwrap()
            .notes
            .is_empty()
    );
    assert!(search(database, "\" ); DROP TABLE catalog; --").is_ok());
    let db = connection(database).unwrap();
    assert!(
        db.query_row("SELECT body FROM note_fts LIMIT 1", [], |r| r
            .get::<_, Option<String>>(0))
            .unwrap()
            .is_none()
    );
    drop(db);
    super::super::save(
        database,
        &note.id,
        "# Updated\nsecondneedle",
        Some(&saved.revision),
    )
    .unwrap();
    list(database).unwrap();
    assert!(search(database, "needledeep").unwrap().notes.is_empty());
    finish(database);
    assert_eq!(search(database, "secondneedle").unwrap().notes.len(), 1);
    let root = root(database).unwrap();
    fs::rename(root.join(&note.id), root.join("renamed.md")).unwrap();
    list(database).unwrap();
    finish(database);
    assert_eq!(
        search(database, "secondneedle").unwrap().notes[0].id,
        "renamed.md"
    );
    fs::remove_file(root.join("renamed.md")).unwrap();
    list(database).unwrap();
    assert!(search(database, "secondneedle").unwrap().notes.is_empty());
    assert_eq!(search(database, "").unwrap().total, 0);
}
#[test]
fn bounds_and_bad_files() {
    let folder = tempfile::tempdir().unwrap();
    let path = folder.path().join("mail.sqlite");
    let database = path.to_str().unwrap();
    let root = root(database).unwrap();
    for n in 0..220 {
        fs::write(
            root.join(format!("note-{n:03}.md")),
            format!("# Common {n}\ncommonbody"),
        )
        .unwrap();
    }
    fs::write(root.join("oversized.md"), vec![b'x'; NOTE_BYTES + 1]).unwrap();
    fs::write(root.join("invalid.md"), [0xff, 0xfe]).unwrap();
    let initial = list(database).unwrap();
    assert!(
        !initial
            .notes
            .iter()
            .find(|n| n.id == "oversized.md")
            .unwrap()
            .available
    );
    finish(database);
    let found = search(database, "commonbody").unwrap();
    assert_eq!(found.notes.len(), MATCH_LIMIT);
    assert_eq!(found.total, 222);
    assert_eq!(found.pending, 0);
    assert_eq!(
        list(database)
            .unwrap()
            .notes
            .iter()
            .filter(|n| !n.available)
            .count(),
        2
    );
    assert!(search(database, &"x".repeat(QUERY_BYTES + 1)).is_err());
    let note = super::super::new(database, None).unwrap();
    list(database).unwrap();
    assert!(step(database, &network::Context::new(None, 0)).is_err());
    assert_eq!(
        super::super::open(database, &note.id).unwrap().text,
        note.text
    );
    assert_eq!(list(database).unwrap().pending, 1);
}
#[test]
#[ignore]
fn notes_search_benchmark() {
    let folder = tempfile::tempdir().unwrap();
    let path = folder.path().join("mail.sqlite");
    let database = path.to_str().unwrap();
    let root = root(database).unwrap();
    for n in 0..NOTE_LIMIT {
        fs::write(
            root.join(format!("note-{n:04}.md")),
            format!(
                "# Daily note {n}\n{}\nunique{n} project planning",
                "paragraph words ".repeat(1000)
            ),
        )
        .unwrap();
    }
    let start = std::time::Instant::now();
    list(database).unwrap();
    finish(database);
    let indexing = start.elapsed().as_secs_f64();
    let mut times = Vec::new();
    for _ in 0..100 {
        let t = std::time::Instant::now();
        assert_eq!(search(database, "unique1999").unwrap().notes.len(), 1);
        times.push(t.elapsed().as_secs_f64() * 1000.0);
    }
    times.sort_by(f64::total_cmp);
    println!(
        "NOTES_BENCH notes={} index_seconds={:.3} search_p95_ms={:.3}",
        NOTE_LIMIT, indexing, times[95]
    );
}
