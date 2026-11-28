//! Python binding for Nasion, exposed as `nasion._nasion`. Holds no domain logic yet.

use pyo3::prelude::*;

const VERSION: &str = env!("CARGO_PKG_VERSION");

#[pymodule]
fn _nasion(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add("__version__", VERSION)
}

#[cfg(test)]
mod tests {
    use super::VERSION;

    #[test]
    fn version_is_not_a_prerelease() {
        assert!(!VERSION.is_empty());
        assert!(!VERSION.contains('-'), "prerelease version {VERSION}");
    }
}
