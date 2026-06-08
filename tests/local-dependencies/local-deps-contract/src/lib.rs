// Re-export simple-contract items to ensure the dependency is properly used
pub use simple_contract;

// Minimal library to satisfy cargo
#[cfg(test)]
mod tests {
    #[test]
    fn it_works() {
        assert_eq!(2 + 2, 4);
    }
}
