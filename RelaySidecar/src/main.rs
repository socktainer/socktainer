use socktainer_port_relay::{parse_cidrs, serve_connection};
use std::fs;
use std::io;
use std::os::unix::net::UnixListener;
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};
use std::thread;

fn required(name: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| panic!("{name} must be set"))
}

fn should_log_connection_error(error: &io::Error) -> bool {
    // The host checks that Apple's published Unix socket is accepting before
    // reusing a relay. That probe deliberately opens and closes without a
    // tunnel preface, which is a clean liveness signal rather than a fault.
    error.kind() != io::ErrorKind::UnexpectedEof
}

fn main() {
    let socket_path = required("SOCKTAINER_RELAY_SOCKET");
    let allowed = Arc::new(
        parse_cidrs(&required("SOCKTAINER_RELAY_CIDRS")).expect("invalid SOCKTAINER_RELAY_CIDRS"),
    );
    let maximum: usize = std::env::var("SOCKTAINER_RELAY_MAX_SESSIONS")
        .unwrap_or_else(|_| "1024".into())
        .parse()
        .expect("invalid SOCKTAINER_RELAY_MAX_SESSIONS");
    let active = Arc::new(AtomicUsize::new(0));
    let _ = fs::remove_file(&socket_path);
    let listener =
        UnixListener::bind(&socket_path).expect("failed to bind SOCKTAINER_RELAY_SOCKET");
    eprintln!("socktainer-port-relay: listening on {socket_path}");
    for incoming in listener.incoming() {
        match incoming {
            Ok(stream) => {
                if active.fetch_add(1, Ordering::AcqRel) >= maximum {
                    active.fetch_sub(1, Ordering::AcqRel);
                    drop(stream);
                    continue;
                }
                let active = active.clone();
                let allowed = allowed.clone();
                thread::spawn(move || {
                    if let Err(error) = serve_connection(stream, &allowed)
                        && should_log_connection_error(&error)
                    {
                        eprintln!("socktainer-port-relay: tunnel ended: {error}");
                    }
                    active.fetch_sub(1, Ordering::AcqRel);
                });
            }
            Err(error) => eprintln!("socktainer-port-relay: accept failed: {error}"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::should_log_connection_error;
    use std::io;

    #[test]
    fn clean_liveness_disconnect_is_silent_but_protocol_errors_are_logged() {
        assert!(!should_log_connection_error(&io::Error::new(
            io::ErrorKind::UnexpectedEof,
            "probe closed"
        )));
        assert!(should_log_connection_error(&io::Error::new(
            io::ErrorKind::InvalidData,
            "bad preface"
        )));
    }
}
