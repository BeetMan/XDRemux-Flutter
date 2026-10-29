use std::env;

fn main() {
    let path = env::args().nth(1).expect("usage: huawei_probe <file.heic>");
    let report = xdremux_core::huawei_heic::inspect_path(path).expect("inspect Huawei HEIC");
    println!("{}", report.to_json());
}
