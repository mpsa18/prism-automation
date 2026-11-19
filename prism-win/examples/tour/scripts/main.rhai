// main.rhai — the tour's scripting example
//
// Rhai is a small language built into Prism. A script can read and write tags,
// log messages and remember values between calls. These functions are called
// according to scripts/bindings.toml.
//
// Useful calls: read("device.tag"), write("device.tag", value), log_info(text),
// is_nan(value), history("device.tag", window_ms).

fn on_init() {
    log_info("Tour script started: waiting for tour_plc.temperature");
}

fn on_close() {
    log_info("Tour script stopped");
}

// Called every 5 seconds by the [[poll]] entry in bindings.toml.
fn tour_tick() {
    let t = read("tour_plc.temperature");
    if is_nan(t) {
        // The device has not delivered a value yet.
        return;
    }
    if t > 70.0 {
        log_info("Tour: temperature is above 70 C");
    }
}
