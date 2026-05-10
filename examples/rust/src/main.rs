fn main() {
    let name = std::env::args().nth(1).unwrap_or_else(|| "world".into());
    println!("{}", greet(&name));
}

pub fn greet(name: &str) -> String {
    assert!(!name.is_empty(), "name must not be empty");
    format!("hello, {name}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn returns_a_friendly_string() {
        assert_eq!(greet("pkf"), "hello, pkf");
    }

    #[test]
    #[should_panic(expected = "must not be empty")]
    fn rejects_empty_input() {
        greet("");
    }
}
