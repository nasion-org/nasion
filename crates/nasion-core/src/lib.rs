//! Core library for Nasion. Holds no domain logic yet.

/// Version of this crate, taken from its manifest at build time.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

#[cfg(test)]
mod tests {
    use super::VERSION;

    #[test]
    fn version_has_three_numeric_parts() {
        let parts: Vec<&str> = VERSION.split('.').collect();
        assert_eq!(parts.len(), 3, "version {VERSION} is not major.minor.patch");
        assert!(parts.iter().all(|p| p.parse::<u64>().is_ok()));
    }
}
