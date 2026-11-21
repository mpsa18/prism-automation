// main.rhai — scripting hooks (commented example)
//
// Rhai is built into Prism. A script can read and write tags, log messages and
// remember values between calls. The functions below are called according to
// scripts/bindings.toml; nothing runs while bindings.toml is commented out.
//
// Useful calls: read("device.tag"), write("device.tag", value),
// log_info(text), is_nan(value), history("device.tag", window_ms).

// fn on_init() {
//     log_info("project started");
// }
//
// fn on_close() {
//     log_info("project stopped");
// }
//
// fn tick() {
//     let value = read("plc1.temperature");
//     if !is_nan(value) && value > 70.0 {
//         log_info("temperature is above 70 C");
//     }
// }
