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
    fn read_args(json: &str) -> Result<Self, Error> {
        let v = serde_json::from_str(json)?;
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
            .map(Deps::sort)
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
    fn sort(mut self) -> Self {
        self.0
            .sort_unstable_by(|lhs, rhs| lhs.user.ns.cmp(&rhs.user.ns));
        self
    }

    fn read_last(base: impl AsRef<Path>) -> Option<Self> {
        let path = base.as_ref().join("last-deps.json");
        let content = std::fs::read_to_string(&path).ok()?;
        log::info!("Found last-deps: {content:?}");
        let v = serde_json::from_str::<Self>(&content).ok()?;
        Some(v.sort())
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
        use std::borrow::Cow;
        use std::collections::HashMap;

        #[derive(Serialize)]
        struct Package {
            name: &'static str,
            version: &'static str,
            edition: &'static str,
        }

        #[derive(Serialize)]
        struct Profile {
            strip: &'static str,
            lto: bool,
        }

        #[derive(Serialize)]
        struct Profiles {
            release: Profile,
        }

        #[derive(Serialize)]
        #[serde(untagged)]
        enum DependencyLocation<'a> {
            Git {
                git: &'a str,
                #[serde(skip_serializing_if = "Option::is_none")]
                branch: Option<&'a str>,
            },
            CratesIo {
                version: &'a str,
            },
            LocalPath {
                path: &'a str,
            },
        }

        #[derive(Serialize)]
        struct Dependency<'a> {
            #[serde(skip_serializing_if = "Option::is_none")]
            package: Option<&'a str>,
            #[serde(skip_serializing_if = "Option::is_none")]
            features: Option<&'a [&'a str]>,
            #[serde(flatten)]
            location: DependencyLocation<'a>,
        }

        #[derive(Serialize)]
        struct Cargo<'a> {
            package: Package,
            profile: Profiles,
            dependencies: HashMap<Cow<'a, str>, Dependency<'a>>,
        }

        let mut dependencies = HashMap::new();
        dependencies.insert(
            Cow::Borrowed("nvim-router"),
            Dependency {
                package: None,
                features: Some(&["tokio"]),
                location: DependencyLocation::Git {
                    git: "https://github.com/naughie/nvim-router.rs.git",
                    branch: Some("main"),
                },
            },
        );
        dependencies.insert(
            Cow::Borrowed("tokio"),
            Dependency {
                package: None,
                features: Some(&["macros", "rt-multi-thread", "sync"]),
                location: DependencyLocation::CratesIo { version: "1" },
            },
        );

        for (i, args, pack) in self.iter() {
            dependencies.insert(
                Cow::Owned(format!("dep{i}")),
                Dependency {
                    package: Some(&pack.name),
                    features: None,
                    location: DependencyLocation::LocalPath { path: &args.path },
                },
            );
        }

        let cargo = Cargo {
            package: Package {
                name: "nvim-router",
                version: "0.1.0",
                edition: "2024",
            },
            profile: Profiles {
                release: Profile {
                    strip: "symbols",
                    lto: true,
                },
            },
            dependencies,
        };

        toml::to_string(&cargo).unwrap_or_default()
    }

    fn bin_main_rs(&self) -> impl Display {
        use quote::{format_ident, quote};

        let dep_mod = self.iter().map(|(i, args, _)| {
            let mod_name = format_ident!("dep{i}");
            let handler = format_ident!("{}", args.handler);
            let ns = &args.ns;

            quote! {
                mod #mod_name {
                    pub use ::#mod_name::#handler as H;
                    #[derive(Clone)]
                    pub struct N;
                    impl nvim_router::Namespace for N {
                        const NS: &str = #ns;
                    }
                }
            }
        });

        let generics = self.iter().map(|(i, _, _)| {
            let mod_name = format_ident!("dep{i}");
            quote! {
                (crate::#mod_name::N, crate::#mod_name::H)
            }
        });

        let init = self.iter().map(|(i, _, _)| {
            let mod_name = format_ident!("dep{i}");
            quote! {
                (
                    crate::#mod_name::N,
                    <crate::#mod_name::H as NeovimHandler<NvimWtr>>::new()
                )
            }
        });

        quote! {
            use std::error::Error;

            use tokio::fs::File as TokioFile;

            use nvim_router::NeovimHandler;
            use nvim_router::Router;
            use nvim_router::nvim_rs::{compat::tokio::Compat, create::tokio as create};

            type NvimWtr = Compat<TokioFile>;

            #( #dep_mod )*

            #[tokio::main]
            async fn main() -> Result<(), Box<dyn Error>> {
                let handler = Router::<NvimWtr, ( #( #generics ),* )>::new(( #( #init ),*));
                let (nvim, io_handler) = create::new_parent(handler).await?;

                match io_handler.await {
                    Err(joinerr) => eprintln!("Error joining IO loop: '{joinerr}'"),
                    Ok(Err(err)) => {
                        if !err.is_reader_error() {
                            nvim.err_writeln(&format!("Error: '{err}'"))
                                .await
                                .unwrap_or_else(|e| {
                                    eprintln!("Well, dang... '{e}'");
                                });
                        }

                        if !err.is_channel_closed() {
                            eprintln!("Error: '{err}'");

                            let mut source = err.source();

                            while let Some(e) = source {
                                eprintln!("Caused by: '{e}'");
                                source = e.source();
                            }
                        }
                    }
                    Ok(Ok(())) => {}
                }

                Ok(())
            }
        }
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

fn build(bin_base: impl AsRef<Path>, deps_json: &str, check_changes: bool) -> Result<(), Error> {
    let bin_base = bin_base.as_ref();

    log::info!(
        "Start building with bin_base = {}, deps_json = {deps_json}, check_changes = {check_changes}",
        bin_base.display(),
    );

    let deps = DepArgs::read_args(deps_json)?.read_metadata()?;
    log::info!("Read deps: {deps:?}");

    if check_changes
        && let Some(last_deps) = Deps::read_last(bin_base)
        && deps == last_deps
    {
        log::info!("Identical deps. Finish.");
        return Ok(());
    }

    create_bin_content(bin_base, &deps)?;
    log::info!("Created a bin project. Building ...");

    let output = Command::new("cargo")
        .args(["build", "--release"])
        .current_dir(bin_base)
        .output()?;

    if output.status.success() {
        deps.write_last(bin_base)?;
        log::info!("Finish.");
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
    use simplelog::{Config, LevelFilter, WriteLogger};

    let log_file = {
        let manifest_dir = env!("CARGO_MANIFEST_DIR");
        let path = Path::new(manifest_dir).join("gen-bin-project.log");
        std::fs::File::create(path)?
    };
    WriteLogger::init(LevelFilter::Info, Config::default(), log_file)?;

    let mut args = std::env::args().skip(1);
    let Some(bin_base) = args.next() else {
        log::error!("Invalid arguments: {:?}", std::env::args());
        return Err(InvalidArgs.into());
    };
    let Some(deps_json) = args.next() else {
        log::error!("Invalid arguments: {:?}", std::env::args());
        return Err(InvalidArgs.into());
    };
    let Some(check_changes) = args.next() else {
        log::error!("Invalid arguments: {:?}", std::env::args());
        return Err(InvalidArgs.into());
    };

    if let Err(e) = build(bin_base, &deps_json, check_changes == "true") {
        log::error!("Error in build: {e}");
        return Err(e);
    }
    Ok(())
}
