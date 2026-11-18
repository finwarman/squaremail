use super::*;
use crate::media::Manifest;

impl Store {
    pub(crate) fn media(&self, id: &str) -> Result<Option<Manifest>> {
        use rusqlite::OptionalExtension;
        let value: Option<String> = self
            .connection
            .query_row(
                "SELECT manifest FROM message_media WHERE message_id=?1",
                [id],
                |r| r.get(0),
            )
            .optional()?;
        value
            .map(|v| serde_json::from_str(&v).map_err(Into::into))
            .transpose()
    }
    pub(crate) fn save_media(&self, id: &str, value: &Manifest) -> Result<()> {
        self.connection.execute("INSERT INTO message_media VALUES(?1,?2) ON CONFLICT(message_id) DO UPDATE SET manifest=excluded.manifest",rusqlite::params![id,serde_json::to_string(value)?])?;
        Ok(())
    }
}
