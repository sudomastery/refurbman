//! Headless CLI. Emits the same JSON the GUI renders, so a power user can
//! script it and CI can assert on it.

fn main() {
    println!("refurbman-probe {}", refurbman_probe::VERSION);
}
