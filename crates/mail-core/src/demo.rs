use crate::{Result, mime, model::*, store::Store};

pub(crate) fn seed(store: &Store) -> Result<()> {
    let account = Account {
        id: "demo".into(),
        email: "Demo mailbox".into(),
        provider: Provider::Local,
    };
    if store.accounts()?.iter().any(|a| a.id == account.id) {
        return Ok(());
    }
    store.save_account(&account)?;
    let notes = [
        (
            "Ada Lovelace",
            "ada@example.test",
            "A small machine for a very full inbox",
            "Hi Fin,\n\nA quiet inbox, a quick search, and a window that gets out of your way. That is the idea.\n\nThis is a local demo message. Connect Gmail or Outlook from Accounts to read your own mail. Nothing here has been sent.\n\nTry the HTML button, search for 'machine', or move through messages with the arrow keys.\n\nAda",
        ),
        (
            "Freya",
            "freya@example.test",
            "Saturday, by the river",
            "Shall we meet at the bookshop at eleven?\n\nI've marked the little café around the corner. We can walk along the river afterwards.\n\nF",
        ),
        (
            "Design workshop",
            "studio@example.test",
            "The details: two pixels, no rounded corners",
            "A note on the interface:\n\nSquare edges. Raised buttons. Inset fields. Blue title bars. Dense tables.\n\nThe chrome is drawn in AppKit. Scrolling, selection, focus and text editing use native controls. The Rust core handles the local mail cache and providers.\n\nThis is an early reader, not a finished mail client.",
        ),
        (
            "Mira Chen",
            "mira@example.test",
            "Re: The catalogue proofs",
            "The second set is ready to review. The paper stock is the same as last time.\n\nCould you check the spacing on page four?\n\nThanks,\nMira",
        ),
        (
            "Rail travel",
            "tickets@example.test",
            "Your journey confirmation",
            "Journey confirmation\n\nLondon Waterloo → Winchester\nSaturday, 21 November\nDepart 09:35 · Arrive 10:32\n\nDemo itinerary. This is not a valid ticket.",
        ),
        (
            "Archive club",
            "archive@example.test",
            "This week's finds: the desktop, 1998",
            "Before everything became a card, there were toolbars.\n\nThis week's collection looks at the small decisions that made desktop software feel direct: stable layouts, clear borders, visible commands, and no waiting for transitions.\n\nThe original VB projects are visual references only. Their code, fonts and icons are not bundled.",
        ),
        (
            "Jon Bell",
            "jon@example.test",
            "Coffee next week?",
            "Tuesday or Thursday works for me. Somewhere near the station?\n\nJon",
        ),
        (
            "Build notes",
            "build@example.test",
            "The offline shelf",
            "Imported .eml files stay on this Mac. Cached provider messages can be read offline once their bodies have been opened.\n\nSearch indexes headers, previews and downloaded text. Sync currently loads the latest 200 headers per chosen folder. Full history and change tracking are still to come.",
        ),
    ];
    for index in 0..48 {
        let (name, address, subject, body) = notes[index % notes.len()];
        let raw = format!(
            "From: {name} <{address}>\r\nTo: Fin <fin@example.test>\r\nSubject: {subject}\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n{body}"
        );
        let mut message = mime::parse(raw.as_bytes(), &account.id, &index.to_string())?;
        message.timestamp = 1794910200 - index as i64 * 3800;
        message.unread = index < 4 || index % 7 == 0;
        message.starred = index % 9 == 0;
        if index == 0 {
            message.html = Some("<div><p>SQUARE MAIL / A NOTE FROM ADA</p><hr><h1>A small machine.<br>A little more quiet.</h1><p>Hi Fin,</p><p>A quiet inbox, a quick search, and a window that gets out of your way. That is the idea.</p><p>This is a <strong>local demo message</strong>. Connect Gmail or Outlook from Accounts to read your own mail.</p><blockquote>Good tools make room for the work.</blockquote><p>Try search, use the arrow keys, or switch back to plain text.</p><p>Ada</p></div>".into());
        }
        let folder = if index >= 44 {
            Folder::Sent
        } else if index >= 40 {
            Folder::Archive
        } else {
            Folder::Inbox
        };
        store.save(&message, folder)?;
    }
    Ok(())
}
