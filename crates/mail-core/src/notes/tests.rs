use super::*;
use std::os::unix::fs::PermissionsExt;

#[test]
fn daily_files_survive_reopen() {
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("mail.sqlite");
    let db = db.to_str().unwrap();
    let first = new(db, Some("2026-11-23")).unwrap();
    assert!(first.text.starts_with("# Monday, 23 November 2026"));
    let text = "# My Monday\n\n- [ ] One\n  - Nested\n\n[Example](https://example.test)\n";
    let saved = save(db, &first.id, text, Some(&first.revision)).unwrap();
    let reopened = new(db, Some("2026-11-23")).unwrap();
    assert_eq!(reopened.id, first.id);
    assert_eq!(reopened.text, text);
    assert_eq!(reopened.revision, saved.revision);
    let listed = list(db).unwrap();
    assert_eq!(listed.notes.len(), 1);
    assert_eq!(listed.notes[0].title, "My Monday");
    let file = root(db).unwrap().join(first.id);
    assert_eq!(
        fs::metadata(file).unwrap().permissions().mode() & 0o777,
        0o600
    );
}
#[test]
fn stale_save_preserves_external() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("mail.sqlite");
    let db = path.to_str().unwrap();
    let note = new(db, None).unwrap();
    fs::write(
        root(db).unwrap().join(&note.id),
        "# Edited elsewhere\nExternal text",
    )
    .unwrap();
    assert!(save(db, &note.id, "My unsaved text", Some(&note.revision)).is_err());
    assert_eq!(
        open(db, &note.id).unwrap().text,
        "# Edited elsewhere\nExternal text"
    );
    assert!(save(db, &note.id, "New file", None).is_err());
    let copy = new(db, None).unwrap();
    save(db, &copy.id, "My unsaved text", Some(&copy.revision)).unwrap();
    assert_eq!(list(db).unwrap().notes.len(), 2);
}
#[test]
fn note_paths_and_bounds() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("mail.sqlite");
    let db = path.to_str().unwrap();
    for id in [
        "../escape.md",
        "/tmp/escape.md",
        "Daily/../../escape.md",
        ".history/old.md",
        "Daily/deep/file.md",
    ] {
        assert!(open(db, id).is_err());
    }
    let note = new(db, None).unwrap();
    let large = "x".repeat(NOTE_BYTES + 1);
    assert!(save(db, &note.id, &large, Some(&note.revision)).is_err());
    let outside = dir.path().join("outside.md");
    fs::write(&outside, "keep").unwrap();
    std::os::unix::fs::symlink(&outside, root(db).unwrap().join("linked.md")).unwrap();
    assert!(open(db, "linked.md").is_err());
    assert!(save(db, "linked.md", "changed", None).is_err());
    assert_eq!(fs::read_to_string(outside).unwrap(), "keep");
}
#[test]
fn saves_keep_bounded_history() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("mail.sqlite");
    let db = path.to_str().unwrap();
    let mut note = new(db, None).unwrap();
    for index in 0..55 {
        note = save(
            db,
            &note.id,
            &format!("# Version {index}"),
            Some(&note.revision),
        )
        .unwrap();
    }
    assert_eq!(
        fs::read_dir(root(db).unwrap().join(".history"))
            .unwrap()
            .count(),
        BACKUP_LIMIT
    );
    assert_eq!(open(db, &note.id).unwrap().text, "# Version 54");
}
