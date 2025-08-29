use std::fmt::{self, Display};
use std::path::Path;
use std::process::Command;

use serde::{Deserialize, Serialize};

type Error = Box<dyn std::error::Error>;

#[derive(Debug, PartialEq, Eq, Deserialize, Serialize)]
struct Package {
    name: String,
    version: String,
}

#[derive(Debug, Deserialize, Serialize)]
struct CargoConfig {
    package: Package,
}

impl CargoConfig {
    fn from_base_path(path: impl AsRef<Path>) -> Result<Self, Error> {
        let path = path.as_ref().join("Cargo.toml");
        let content = std::fs::read_to_string(path)?;
        let v = toml::from_str(&content)?;
        Ok(v)
    }
}

#[derive(Debug, PartialEq, Eq, Deserialize, Serialize)]
struct DepArg {
    path: String,
    handler: String,
    ns: String,
}

#[derive(Debug, Deserialize, Serialize)]
struct DepArgs(Vec<DepArg>);

impl DepArgs {
    fn read_args(base: impl AsRef<Path>) -> Result<Self, Error> {
        let path = base.as_ref().join("deps.json");
        let content = std::fs::read_to_string(path)?;
        let v = serde_json::from_str(&content)?;
        Ok(v)
    }

    fn read_metadata(self) -> Result<Deps, Error> {
        self.0
            .into_iter()
            .map(|dep| {
                let cargo = CargoConfig::from_base_path(&dep.path);
                cargo.map(|cargo| Dep {
                    user: dep,
                    auto: cargo.package,
                })
            })
            .collect::<Result<Vec<_>, _>>()
            .map(Deps)
    }
}

#[derive(Debug, PartialEq, Eq, Deserialize, Serialize)]
struct Dep {
    user: DepArg,
    auto: Package,
}

#[derive(Debug, PartialEq, Eq, Deserialize, Serialize)]
struct Deps(Vec<Dep>);

impl Deps {
    fn read_last(base: impl AsRef<Path>) -> Option<Self> {
        let path = base.as_ref().join("last-deps.json");
        let content = std::fs::read_to_string(path).ok()?;
        let v = serde_json::from_str(&content).ok()?;
        Some(v)
    }

    fn write_last(&self, base: impl AsRef<Path>) -> Result<(), Error> {
        let path = base.as_ref().join("last-deps.json");
        let content = serde_json::to_string(self)?;
        std::fs::write(path, content)?;
        Ok(())
    }

    fn iter(&self) -> impl Iterator<Item = (usize, &DepArg, &Package)> {
        self.0
            .iter()
            .enumerate()
            .map(|(i, dep)| (i, &dep.user, &dep.auto))
    }

    fn bin_cargo_toml(&self) -> impl Display {
        struct Inner<'a>(&'a Deps);

        impl Display for Inner<'_> {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                writeln!(
                    f,
                    r#"
                        [package]
                        name = "nvim-router"
                        version = "0.1.0"
                        edition = "2024"

                        [profile.release]
                        strip = "symbols"
                        lto = true

                        [dependencies]
                        nvim-router = {{ git = "https://github.com/naughie/nvim-router.rs.git", branch = "main", features = ["tokio"] }}
                        tokio = {{ version = "1", features = ["macros", "rt-multi-thread", "sync"] }}
                    "#
                )?;

                for (i, args, pack) in self.0.iter() {
                    writeln!(
                        f,
                        r#"dep{i} = {{ package = "{}", path = "{}" }}"#,
                        pack.name, args.path,
                    )?;
                }
                Ok(())
            }
        }

        Inner(self)
    }

    fn bin_main_rs(&self) -> impl Display {
        struct Namespace<'a>(&'a str);

        impl Display for Namespace<'_> {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                for c in self.0.chars() {
                    write!(f, "{}", c.escape_default())?;
                }
                Ok(())
            }
        }

        struct Inner<'a>(&'a Deps);

        impl Display for Inner<'_> {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                writeln!(
                    f,
                    r#"
                        use std::error::Error;

                        use tokio::fs::File as TokioFile;

                        use nvim_router::NeovimHandler;
                        use nvim_router::Router;
                        use nvim_router::nvim_rs::{{compat::tokio::Compat, create::tokio as create}};

                        type NvimWtr = Compat<TokioFile>;
                    "#
                )?;

                for (i, args, _) in self.0.iter() {
                    writeln!(
                        f,
                        r#"
                            mod dep{i} {{
                                pub use ::dep{i}::{} as H;
                                #[derive(Clone)]
                                pub struct N;
                                impl nvim_router::Namespace for N {{
                                    const NS: &str = "{}";
                                }}
                            }}
                        "#,
                        args.handler,
                        Namespace(&args.ns),
                    )?;
                }

                writeln!(
                    f,
                    r#"
                        #[tokio::main]
                        async fn main() -> Result<(), Box<dyn Error>> {{
                            let handler = Router::<NvimWtr, (
                    "#
                )?;

                for (i, _, _) in self.0.iter() {
                    writeln!(
                        f,
                        r#"
                            (crate::dep{i}::N, crate::dep{i}::H),
                        "#,
                    )?;
                }

                writeln!(
                    f,
                    r#"
                        )>::new((
                    "#
                )?;

                for (i, _, _) in self.0.iter() {
                    writeln!(
                        f,
                        r#"
                            (crate::dep{i}::N, <crate::dep{i}::H as NeovimHandler<NvimWtr>>::new()),
                        "#,
                    )?;
                }

                writeln!(
                    f,
                    r#"
                            ));
                            let (nvim, io_handler) = create::new_parent(handler).await?;

                            match io_handler.await {{
                                Err(joinerr) => eprintln!("Error joining IO loop: '{{joinerr}}'"),
                                Ok(Err(err)) => {{
                                    if !err.is_reader_error() {{
                                        nvim.err_writeln(&format!("Error: '{{err}}'"))
                                            .await
                                            .unwrap_or_else(|e| {{
                                                eprintln!("Well, dang... '{{e}}'");
                                            }});
                                    }}

                                    if !err.is_channel_closed() {{
                                        eprintln!("Error: '{{err}}'");

                                        let mut source = err.source();

                                        while let Some(e) = source {{
                                            eprintln!("Caused by: '{{e}}'");
                                            source = e.source();
                                        }}
                                    }}
                                }}
                                Ok(Ok(())) => {{}}
                            }}

                            Ok(())
                        }}
                    "#
                )?;

                Ok(())
            }
        }

        Inner(self)
    }
}

fn create_bin_content(base: impl AsRef<Path>, deps: &Deps) -> Result<(), Error> {
    fn mkdir_unless_exists(path: impl AsRef<Path>) -> Result<(), Error> {
        let path = path.as_ref();
        if !path.exists() {
            std::fs::create_dir(path)?;
        }
        Ok(())
    }

    fn write_to_file(path: impl AsRef<Path>, content: impl Display) -> Result<(), Error> {
        std::fs::write(path, content.to_string())?;
        Ok(())
    }

    let base = base.as_ref();

    mkdir_unless_exists(base)?;
    write_to_file(base.join("Cargo.toml"), deps.bin_cargo_toml())?;
    let src = base.join("src");
    mkdir_unless_exists(&src)?;
    write_to_file(src.join("main.rs"), deps.bin_main_rs())?;

    Ok(())
}

fn build(
    bin_base: impl AsRef<Path>,
    gen_base: impl AsRef<Path>,
    check_changes: bool,
) -> Result<(), Error> {
    let bin_base = bin_base.as_ref();
    let gen_base = gen_base.as_ref();

    let deps = DepArgs::read_args(gen_base)?.read_metadata()?;

    if check_changes
        && let Some(last_deps) = Deps::read_last(bin_base)
        && deps == last_deps
    {
        return Ok(());
    }

    create_bin_content(bin_base, &deps)?;

    let output = Command::new("cargo")
        .args(["build", "--release"])
        .current_dir(bin_base)
        .output()?;

    if output.status.success() {
        deps.write_last(bin_base)?;
    }

    Ok(())
}

struct InvalidArgs;

impl fmt::Debug for InvalidArgs {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        <Self as Display>::fmt(self, f)
    }
}
impl Display for InvalidArgs {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        writeln!(
            f,
            "Invilad arguments. Usage: cargo run --release bin_base check_changes"
        )
    }
}
impl std::error::Error for InvalidArgs {}

fn main() -> Result<(), Error> {
    let mut args = std::env::args().skip(1);
    let Some(bin_base) = args.next() else {
        return Err(InvalidArgs.into());
    };
    let Some(check_changes) = args.next() else {
        return Err(InvalidArgs.into());
    };

    build(bin_base, ".", check_changes == "true")
}
