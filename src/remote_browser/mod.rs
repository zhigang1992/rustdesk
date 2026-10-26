const TARGET_PREFIX: &str = "rustdesk-browser-v1-";
pub const SOCKS_USERNAME: &str = "rustdesk";

pub fn target(token: &str) -> String {
    format!("{}{}", TARGET_PREFIX, token)
}

pub fn token(host: &str, port: i32) -> Option<&str> {
    let token = host.strip_prefix(TARGET_PREFIX)?;
    if port != 0 || uuid::Uuid::parse_str(token).ok()?.to_string() != token {
        return None;
    }
    Some(token)
}

#[cfg(target_os = "ios")]
pub mod client;
#[cfg(any(target_os = "macos", test))]
pub mod socks;
#[cfg(any(target_os = "macos", test))]
mod loopback;

#[cfg(test)]
mod tests {
    #[test]
    fn browser_target_requires_a_session_token_and_reserved_port() {
        let token = "5981d37d-1094-4217-9e43-23e51365304c";
        assert_eq!(super::token(&super::target(token), 0), Some(token));
        assert_eq!(super::token(&super::target(token), 80), None);
        assert_eq!(super::token("localhost", 0), None);
        assert_eq!(super::token("rustdesk-browser-v1-invalid", 0), None);
    }
}
