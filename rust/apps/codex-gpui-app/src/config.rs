use std::{env, path::PathBuf};

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct RunConfiguration {
    pub(crate) codex_binary: PathBuf,
    pub(crate) cwd: PathBuf,
    pub(crate) prompt: String,
    pub(crate) prompt_explicit: bool,
    pub(crate) ephemeral: bool,
    pub(crate) headless: bool,
    pub(crate) queued_prompt: Option<String>,
}

impl RunConfiguration {
    pub(crate) fn parse(arguments: impl IntoIterator<Item = String>) -> Result<Self, String> {
        let mut codex_binary =
            env::var_os("CODEX_BINARY").map_or_else(|| PathBuf::from("codex"), PathBuf::from);
        let mut cwd = env::current_dir().map_err(|error| error.to_string())?;
        let mut prompt = "Introduce yourself in one short sentence. Do not use tools.".to_owned();
        let mut prompt_explicit = false;
        let mut ephemeral = false;
        let mut headless = false;
        let mut queued_prompt = None;
        let mut arguments = arguments.into_iter();
        while let Some(argument) = arguments.next() {
            match argument.as_str() {
                "--codex-binary" => {
                    codex_binary = PathBuf::from(next_value(&mut arguments, &argument)?);
                }
                "--cwd" => cwd = PathBuf::from(next_value(&mut arguments, &argument)?),
                "--prompt" => {
                    prompt = next_value(&mut arguments, &argument)?;
                    prompt_explicit = true;
                }
                "--persist" => ephemeral = false,
                "--ephemeral" => ephemeral = true,
                "--headless" => headless = true,
                "--queue" => queued_prompt = Some(next_value(&mut arguments, &argument)?),
                "--help" | "-h" => return Err(usage().to_owned()),
                value => return Err(format!("unknown argument {value:?}\n{}", usage())),
            }
        }
        if prompt.trim().is_empty() {
            return Err("--prompt must not be empty".to_owned());
        }
        if ephemeral && queued_prompt.is_some() {
            return Err("--queue requires a persisted thread; remove --ephemeral".to_owned());
        }
        Ok(Self {
            codex_binary,
            cwd,
            prompt,
            prompt_explicit,
            ephemeral,
            headless,
            queued_prompt,
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
    "usage: codex-gpui-app [--codex-binary PATH] [--cwd PATH] [--prompt TEXT] [--ephemeral] [--headless] [--queue TEXT]"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_explicit_overrides() {
        let config = RunConfiguration::parse([
            "--codex-binary".to_owned(),
            "/bin/codex".to_owned(),
            "--cwd".to_owned(),
            "/workspace".to_owned(),
            "--prompt".to_owned(),
            "hello".to_owned(),
            "--persist".to_owned(),
            "--headless".to_owned(),
            "--queue".to_owned(),
            "follow up".to_owned(),
        ])
        .expect("configuration");
        assert_eq!(config.codex_binary, PathBuf::from("/bin/codex"));
        assert_eq!(config.cwd, PathBuf::from("/workspace"));
        assert_eq!(config.prompt, "hello");
        assert!(config.prompt_explicit);
        assert!(!config.ephemeral);
        assert!(config.headless);
        assert_eq!(config.queued_prompt.as_deref(), Some("follow up"));
    }

    #[test]
    fn reference_host_persists_threads_unless_ephemeral_is_explicit() {
        let persistent = RunConfiguration::parse(Vec::<String>::new()).expect("defaults");
        assert!(!persistent.ephemeral);
        assert!(!persistent.prompt_explicit);
        let ephemeral =
            RunConfiguration::parse(["--ephemeral".to_owned()]).expect("ephemeral override");
        assert!(ephemeral.ephemeral);
    }

    #[test]
    fn rejects_durable_queue_for_ephemeral_threads() {
        let error = RunConfiguration::parse([
            "--ephemeral".to_owned(),
            "--queue".to_owned(),
            "follow up".to_owned(),
        ])
        .expect_err("ephemeral queue must be rejected");
        assert!(error.contains("persisted thread"));
    }
}
