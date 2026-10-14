use std::env;
use std::path::Path;

fn main() {
    let crate_dir = env::var("CARGO_MANIFEST_DIR").unwrap();
    let config_path = Path::new(&crate_dir).join("cbindgen.toml");

    println!("cargo:warning=Loading config from: {:?}", config_path);

    let config = cbindgen::Config::from_file(&config_path).expect("Unable to load cbindgen config");

    println!("cargo:warning=Config loaded successfully");

    let bindings = cbindgen::Builder::new()
        .with_config(config)
        .with_crate(crate_dir)
        .generate()
        .expect("Unable to generate bindings");

    println!("cargo:warning=Bindings generated, writing to file");

    bindings.write_to_file("bindings.h");

    println!("cargo:warning=Bindings written");
}
