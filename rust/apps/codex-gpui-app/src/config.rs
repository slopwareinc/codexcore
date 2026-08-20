use std::{env, path::PathBuf};

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct RunConfiguration {
    pub(crate) codex_binary: PathBuf,
    pub(crate) cwd: PathBuf,
    pub(crate) prompt: String,
    pub(crate) ephemeral: bool,
    pub(crate) headless: bool,
}

impl RunConfiguration {
    pub(crate) fn parse(arguments: impl IntoIterator<Item = String>) -> Result<Self, String> {
        let mut codex_binary =
            env::var_os("CODEX_BINARY").map_or_else(|| PathBuf::from("codex"), PathBuf::from);
        let mut cwd = env::current_dir().map_err(|error| error.to_string())?;
        let mut prompt = "Introduce yourself in one short sentence. Do not use tools.".to_owned();
        let mut ephemeral = true;
        let mut headless = false;
        let mut arguments = arguments.into_iter();
        while let Some(argument) = arguments.next() {
            match argument.as_str() {
                "--codex-binary" => {
                    codex_binary = PathBuf::from(next_value(&mut arguments, &argument)?);
                }
                "--cwd" => cwd = PathBuf::from(next_value(&mut arguments, &argument)?),
                "--prompt" => prompt = next_value(&mut arguments, &argument)?,
                "--persist" => ephemeral = false,
                "--headless" => headless = true,
                "--help" | "-h" => return Err(usage().to_owned()),
                value => return Err(format!("unknown argument {value:?}\n{}", usage())),
            }
        }
        if prompt.trim().is_empty() {
            return Err("--prompt must not be empty".to_owned());
        }
        Ok(Self {
            codex_binary,
            cwd,
            prompt,
            ephemeral,
            headless,
        })
    }
}

fn next_value(
    arguments: &mut impl Iterator<Item = String>,
    option: &str,
) -> Result<String, String> {
    arguments
        .next()
        .ok_or_else(|| format!("{option} requires a value"))
}

const fn usage() -> &'static str {
    "usage: codex-gpui-app [--codex-binary PATH] [--cwd PATH] [--prompt TEXT] [--persist] [--headless]"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_safe_ephemeral_defaults_and_explicit_overrides() {
        let config = RunConfiguration::parse([
            "--codex-binary".to_owned(),
            "/bin/codex".to_owned(),
            "--cwd".to_owned(),
            "/workspace".to_owned(),
            "--prompt".to_owned(),
            "hello".to_owned(),
            "--persist".to_owned(),
            "--headless".to_owned(),
        ])
        .expect("configuration");
        assert_eq!(config.codex_binary, PathBuf::from("/bin/codex"));
        assert_eq!(config.cwd, PathBuf::from("/workspace"));
        assert_eq!(config.prompt, "hello");
        assert!(!config.ephemeral);
        assert!(config.headless);
    }
}
