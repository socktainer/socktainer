//! Guest endpoint for Socktainer's Apple-published Unix-socket port relay.

use std::io::{self, Read, Write};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, Shutdown, SocketAddr, TcpStream, UdpSocket};
use std::os::unix::net::UnixStream;
use std::thread;
use std::time::Duration;

pub const MAGIC: [u8; 4] = *b"SKTR";
pub const VERSION: u8 = 2;
pub const PREFACE_SIZE: usize = 26;
pub const ACK_MAGIC: [u8; 4] = *b"SKTA";
pub const ACK_SIZE: usize = 8;
pub const MAX_UDP_DATAGRAM: usize = 65_507;
pub const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum Transport {
    Tcp = 1,
    Udp = 2,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum ConnectStatus {
    Ready = 0,
    ConnectionRefused = 1,
    RouteUnavailable = 2,
    TimedOut = 3,
    Denied = 4,
    Failed = 255,
}

impl ConnectStatus {
    pub fn encode(self) -> [u8; ACK_SIZE] {
        [
            ACK_MAGIC[0],
            ACK_MAGIC[1],
            ACK_MAGIC[2],
            ACK_MAGIC[3],
            VERSION,
            self as u8,
            0,
            0,
        ]
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Preface {
    pub transport: Transport,
    pub target: SocketAddr,
}

impl Preface {
    pub fn encode(self) -> [u8; PREFACE_SIZE] {
        let mut bytes = [0u8; PREFACE_SIZE];
        bytes[0..4].copy_from_slice(&MAGIC);
        bytes[4] = VERSION;
        bytes[5] = self.transport as u8;
        bytes[6] = if self.target.is_ipv4() { 4 } else { 6 };
        bytes[8..10].copy_from_slice(&self.target.port().to_be_bytes());
        match self.target.ip() {
            IpAddr::V4(ip) => bytes[10..14].copy_from_slice(&ip.octets()),
            IpAddr::V6(ip) => bytes[10..26].copy_from_slice(&ip.octets()),
        }
        bytes
    }

    pub fn read_from(mut input: impl Read) -> io::Result<Self> {
        let mut bytes = [0u8; PREFACE_SIZE];
        input.read_exact(&mut bytes)?;
        if bytes[0..4] != MAGIC || bytes[4] != VERSION || bytes[7] != 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid relay preface",
            ));
        }
        let transport = match bytes[5] {
            1 => Transport::Tcp,
            2 => Transport::Udp,
            _ => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "invalid relay transport",
                ));
            }
        };
        let port = u16::from_be_bytes([bytes[8], bytes[9]]);
        if port == 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "relay target port is zero",
            ));
        }
        let ip = match bytes[6] {
            4 if bytes[14..26] == [0; 12] => {
                IpAddr::V4(Ipv4Addr::new(bytes[10], bytes[11], bytes[12], bytes[13]))
            }
            6 => IpAddr::V6(Ipv6Addr::from(
                <[u8; 16]>::try_from(&bytes[10..26]).unwrap(),
            )),
            _ => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "invalid relay address family",
                ));
            }
        };
        Ok(Self {
            transport,
            target: SocketAddr::new(ip, port),
        })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Cidr {
    network: IpAddr,
    prefix: u8,
}

impl Cidr {
    pub fn parse(value: &str) -> io::Result<Self> {
        let (network, prefix) = value
            .split_once('/')
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "CIDR requires a prefix"))?;
        let network: IpAddr = network
            .parse()
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid CIDR address"))?;
        let prefix: u8 = prefix
            .parse()
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid CIDR prefix"))?;
        if prefix > if network.is_ipv4() { 32 } else { 128 } {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "CIDR prefix is out of range",
            ));
        }
        Ok(Self { network, prefix })
    }

    pub fn contains(self, address: IpAddr) -> bool {
        match (self.network, address) {
            (IpAddr::V4(network), IpAddr::V4(address)) => {
                let mask = if self.prefix == 0 {
                    0
                } else {
                    u32::MAX << (32 - self.prefix)
                };
                u32::from(network) & mask == u32::from(address) & mask
            }
            (IpAddr::V6(network), IpAddr::V6(address)) => {
                let mask = if self.prefix == 0 {
                    0
                } else {
                    u128::MAX << (128 - self.prefix)
                };
                u128::from(network) & mask == u128::from(address) & mask
            }
            _ => false,
        }
    }
}

pub fn parse_cidrs(value: &str) -> io::Result<Vec<Cidr>> {
    let cidrs: Vec<Cidr> = value
        .split(',')
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(Cidr::parse)
        .collect::<io::Result<_>>()?;
    if cidrs.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "at least one relay CIDR is required",
        ));
    }
    Ok(cidrs)
}

/// Handles one connection delivered through Apple Container's published socket.
pub fn serve_connection(mut host: UnixStream, allowed: &[Cidr]) -> io::Result<()> {
    let preface = Preface::read_from(&mut host)?;
    if !allowed
        .iter()
        .any(|cidr| cidr.contains(preface.target.ip()))
    {
        host.write_all(&ConnectStatus::Denied.encode())?;
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "relay target is outside the configured network",
        ));
    }
    match preface.transport {
        Transport::Tcp => relay_tcp(host, preface.target),
        Transport::Udp => relay_udp(host, preface.target),
    }
}

fn relay_tcp(mut host: UnixStream, target: SocketAddr) -> io::Result<()> {
    let mut guest = match TcpStream::connect_timeout(&target, CONNECT_TIMEOUT) {
        Ok(guest) => guest,
        Err(error) => {
            host.write_all(&connect_status(&error).encode())?;
            return Err(error);
        }
    };
    if let Err(error) = guest.set_nodelay(true) {
        host.write_all(&ConnectStatus::Failed.encode())?;
        return Err(error);
    }
    host.write_all(&ConnectStatus::Ready.encode())?;
    let mut host_reader = host.try_clone()?;
    let mut guest_reader = guest.try_clone()?;

    let upload = thread::spawn(move || {
        let result = io::copy(&mut host_reader, &mut guest);
        let _ = guest.shutdown(Shutdown::Write);
        result
    });
    let download = io::copy(&mut guest_reader, &mut host);
    let _ = host.shutdown(Shutdown::Write);
    let upload = upload
        .join()
        .map_err(|_| io::Error::other("TCP relay worker panicked"))?;
    upload?;
    download?;
    Ok(())
}

fn read_datagram(mut input: impl Read) -> io::Result<Option<Vec<u8>>> {
    let mut length = [0u8; 2];
    match input.read(&mut length[..1])? {
        0 => return Ok(None),
        1 => input.read_exact(&mut length[1..])?,
        _ => unreachable!(),
    }
    let length = u16::from_be_bytes(length) as usize;
    let mut datagram = vec![0u8; length];
    input.read_exact(&mut datagram)?;
    Ok(Some(datagram))
}

fn write_datagram(mut output: impl Write, datagram: &[u8]) -> io::Result<()> {
    if datagram.len() > u16::MAX as usize {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "UDP datagram is too large",
        ));
    }
    output.write_all(&(datagram.len() as u16).to_be_bytes())?;
    output.write_all(datagram)?;
    output.flush()
}

fn relay_udp(mut host: UnixStream, target: SocketAddr) -> io::Result<()> {
    let guest = match UdpSocket::bind(if target.is_ipv4() {
        "0.0.0.0:0"
    } else {
        "[::]:0"
    }) {
        Ok(guest) => guest,
        Err(error) => {
            host.write_all(&ConnectStatus::Failed.encode())?;
            return Err(error);
        }
    };
    if let Err(error) = guest.connect(target) {
        host.write_all(&connect_status(&error).encode())?;
        return Err(error);
    }
    host.write_all(&ConnectStatus::Ready.encode())?;
    guest.set_read_timeout(Some(Duration::from_secs(1)))?;
    let guest_reader = guest.try_clone()?;
    let mut host_reader = host.try_clone()?;

    let upload = thread::spawn(move || -> io::Result<()> {
        while let Some(datagram) = read_datagram(&mut host_reader)? {
            if datagram.len() > MAX_UDP_DATAGRAM {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "UDP datagram exceeds protocol maximum",
                ));
            }
            guest.send(&datagram)?;
        }
        Ok(())
    });

    let mut datagram = vec![0u8; MAX_UDP_DATAGRAM];
    loop {
        match guest_reader.recv(&mut datagram) {
            Ok(length) => write_datagram(&mut host, &datagram[..length])?,
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
                ) => {}
            Err(error) => return Err(error),
        }
        if upload.is_finished() {
            break;
        }
    }
    upload
        .join()
        .map_err(|_| io::Error::other("UDP relay worker panicked"))??;
    Ok(())
}

fn connect_status(error: &io::Error) -> ConnectStatus {
    match error.raw_os_error() {
        Some(61 | 111) => ConnectStatus::ConnectionRefused,
        Some(51 | 65 | 101 | 113) => ConnectStatus::RouteUnavailable,
        Some(60 | 110) => ConnectStatus::TimedOut,
        _ => ConnectStatus::Failed,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;

    #[test]
    fn preface_round_trips_ipv4_and_ipv6() {
        for expected in [
            Preface {
                transport: Transport::Tcp,
                target: "192.168.65.4:5432".parse().unwrap(),
            },
            Preface {
                transport: Transport::Udp,
                target: "[fd00::1234]:5353".parse().unwrap(),
            },
        ] {
            assert_eq!(
                Preface::read_from(&expected.encode()[..]).unwrap(),
                expected
            );
        }
    }

    #[test]
    fn preface_rejects_unknown_version_and_noncanonical_ipv4() {
        let mut bytes = Preface {
            transport: Transport::Tcp,
            target: "127.0.0.1:80".parse().unwrap(),
        }
        .encode();
        bytes[4] = VERSION.wrapping_add(1);
        assert_eq!(
            Preface::read_from(&bytes[..]).unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
        bytes = Preface {
            transport: Transport::Tcp,
            target: "127.0.0.1:80".parse().unwrap(),
        }
        .encode();
        bytes[7] = 1;
        assert_eq!(
            Preface::read_from(&bytes[..]).unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
        bytes[4] = VERSION;
        bytes[25] = 1;
        assert_eq!(
            Preface::read_from(&bytes[..]).unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
    }

    #[test]
    fn tcp_relay_is_full_duplex_and_preserves_half_close() {
        let target = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = target.local_addr().unwrap();
        thread::spawn(move || {
            let (mut connection, _) = target.accept().unwrap();
            let mut request = Vec::new();
            connection.read_to_end(&mut request).unwrap();
            assert_eq!(request, b"select 1");
            connection.write_all(b"row:1").unwrap();
        });
        let (mut host, guest) = UnixStream::pair().unwrap();
        thread::spawn(move || {
            serve_connection(guest, &[Cidr::parse("127.0.0.0/8").unwrap()]).unwrap()
        });
        host.write_all(
            &Preface {
                transport: Transport::Tcp,
                target: address,
            }
            .encode(),
        )
        .unwrap();
        let mut acknowledgement = [0u8; ACK_SIZE];
        host.read_exact(&mut acknowledgement).unwrap();
        assert_eq!(acknowledgement, ConnectStatus::Ready.encode());
        host.write_all(b"select 1").unwrap();
        host.shutdown(Shutdown::Write).unwrap();
        let mut response = Vec::new();
        host.read_to_end(&mut response).unwrap();
        assert_eq!(response, b"row:1");
    }

    #[test]
    fn tcp_refusal_is_reported_before_the_stream_closes() {
        let target = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = target.local_addr().unwrap();
        drop(target);
        let (mut host, guest) = UnixStream::pair().unwrap();
        thread::spawn(move || {
            let _ = serve_connection(guest, &[Cidr::parse("127.0.0.0/8").unwrap()]);
        });
        host.write_all(
            &Preface {
                transport: Transport::Tcp,
                target: address,
            }
            .encode(),
        )
        .unwrap();
        let mut acknowledgement = [0u8; ACK_SIZE];
        host.read_exact(&mut acknowledgement).unwrap();
        assert_eq!(acknowledgement, ConnectStatus::ConnectionRefused.encode());
    }

    #[test]
    fn udp_relay_preserves_datagram_boundaries() {
        let target = UdpSocket::bind("127.0.0.1:0").unwrap();
        let address = target.local_addr().unwrap();
        thread::spawn(move || {
            for _ in 0..2 {
                let mut request = [0u8; 128];
                let (length, peer) = target.recv_from(&mut request).unwrap();
                let mut response = b"reply:".to_vec();
                response.extend_from_slice(&request[..length]);
                target.send_to(&response, peer).unwrap();
            }
        });
        let (mut host, guest) = UnixStream::pair().unwrap();
        thread::spawn(move || {
            serve_connection(guest, &[Cidr::parse("127.0.0.0/8").unwrap()]).unwrap()
        });
        host.write_all(
            &Preface {
                transport: Transport::Udp,
                target: address,
            }
            .encode(),
        )
        .unwrap();
        let mut acknowledgement = [0u8; ACK_SIZE];
        host.read_exact(&mut acknowledgement).unwrap();
        assert_eq!(acknowledgement, ConnectStatus::Ready.encode());
        write_datagram(&mut host, b"first").unwrap();
        write_datagram(&mut host, b"second-packet").unwrap();
        assert_eq!(read_datagram(&mut host).unwrap().unwrap(), b"reply:first");
        assert_eq!(
            read_datagram(&mut host).unwrap().unwrap(),
            b"reply:second-packet"
        );
    }

    #[test]
    fn cidr_enforces_network_boundary() {
        let v4 = Cidr::parse("192.168.64.0/24").unwrap();
        assert!(v4.contains("192.168.64.99".parse().unwrap()));
        assert!(!v4.contains("192.168.65.1".parse().unwrap()));
        assert!(!v4.contains("fd00::1".parse().unwrap()));
        let v6 = Cidr::parse("fd00:1234::/32").unwrap();
        assert!(v6.contains("fd00:1234::abcd".parse().unwrap()));
        assert!(!v6.contains("fd01::1".parse().unwrap()));
    }

    #[test]
    fn udp_rejects_truncated_length_prefix() {
        let error = read_datagram(&[0x01][..]).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::UnexpectedEof);
    }

    #[test]
    fn connection_rejects_destination_outside_network() {
        let (mut host, guest) = UnixStream::pair().unwrap();
        let worker =
            thread::spawn(move || serve_connection(guest, &[Cidr::parse("10.0.0.0/8").unwrap()]));
        host.write_all(
            &Preface {
                transport: Transport::Tcp,
                target: "127.0.0.1:80".parse().unwrap(),
            }
            .encode(),
        )
        .unwrap();
        let mut acknowledgement = [0u8; ACK_SIZE];
        host.read_exact(&mut acknowledgement).unwrap();
        assert_eq!(acknowledgement, ConnectStatus::Denied.encode());
        assert_eq!(
            worker.join().unwrap().unwrap_err().kind(),
            io::ErrorKind::PermissionDenied
        );
    }
}
