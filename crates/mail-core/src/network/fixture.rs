use serde_json::Value;
use std::{
    io::{Read, Write},
    net::TcpListener,
    sync::{Arc, Mutex},
    thread,
    time::{Duration, Instant},
};
#[derive(Clone)]
pub(crate) struct Request {
    pub(crate) line: String,
    pub(crate) headers: String,
    pub(crate) value: Value,
}
pub(crate) struct Fixture {
    pub(crate) root: String,
    worker: Option<thread::JoinHandle<()>>,
    requests: Arc<Mutex<Vec<Request>>>,
}
impl Fixture {
    pub(crate) fn new(replies: Vec<(&str, u16, Option<Value>)>) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let root = format!("http://{}", listener.local_addr().unwrap());
        let replies = replies
            .into_iter()
            .map(|(path, status, value)| (path.to_string(), status, value))
            .collect::<Vec<_>>();
        let requests = Arc::new(Mutex::new(Vec::new()));
        let saved = requests.clone();
        let worker = thread::spawn(move || {
            for (path, status, value) in replies {
                let begin = Instant::now();
                let mut stream = loop {
                    match listener.accept() {
                        Ok((s, _)) => break s,
                        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                            assert!(begin.elapsed() < Duration::from_secs(3), "Missing {path}");
                            thread::sleep(Duration::from_millis(2));
                        }
                        Err(e) => panic!("{e}"),
                    }
                };
                stream.set_nonblocking(false).unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(2)))
                    .unwrap();
                let mut raw = Vec::new();
                let mut buf = [0; 4096];
                let end = loop {
                    let n = stream.read(&mut buf).unwrap();
                    assert!(n > 0);
                    raw.extend_from_slice(&buf[..n]);
                    if let Some(i) = raw.windows(4).position(|v| v == b"\r\n\r\n") {
                        break i + 4;
                    }
                };
                let headers = String::from_utf8_lossy(&raw[..end]).to_string();
                assert!(
                    headers.starts_with(&path),
                    "{} does not match {path}",
                    headers.lines().next().unwrap()
                );
                let length = headers
                    .lines()
                    .find_map(|s| {
                        s.to_lowercase()
                            .strip_prefix("content-length: ")
                            .and_then(|v| v.parse::<usize>().ok())
                    })
                    .unwrap_or(0);
                while raw.len() < end + length {
                    let n = stream.read(&mut buf).unwrap();
                    assert!(n > 0);
                    raw.extend_from_slice(&buf[..n]);
                }
                let body = if length == 0 {
                    Value::Null
                } else {
                    serde_json::from_slice(&raw[end..end + length]).unwrap()
                };
                saved.lock().unwrap().push(Request {
                    line: headers.lines().next().unwrap().into(),
                    headers,
                    value: body,
                });
                let body = value.map(|v| v.to_string()).unwrap_or_default();
                write!(stream,"HTTP/1.1 {status} Synthetic\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len()).unwrap();
            }
        });
        Self {
            root,
            worker: Some(worker),
            requests,
        }
    }
    pub(crate) fn finish(mut self) -> Vec<Request> {
        self.worker.take().unwrap().join().unwrap();
        self.requests.lock().unwrap().clone()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}
