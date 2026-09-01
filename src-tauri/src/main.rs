// The console window is suppressed on Windows release builds: a black box
// appearing behind the application looks like something went wrong.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    refurbman_app_lib::run()
}
