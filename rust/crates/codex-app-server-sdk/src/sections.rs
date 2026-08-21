use codex_app_server_client::AppServerClient;
use codex_app_server_state::ThreadId;
use serde::Deserialize;
use serde_json::{Map, Value, json};

use crate::SdkError;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SectionAppearance {
    pub icon: Option<String>,
    pub color: Option<String>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub enum SectionAppearanceUpdate {
    #[default]
    Preserve,
    Clear,
    Set(SectionAppearance),
}

impl SectionAppearance {
    fn into_value(self) -> Value {
        json!({"icon": self.icon, "color": self.color})
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ThreadSection {
    pub id: String,
    pub name: String,
    pub appearance: Option<SectionAppearance>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SectionPage {
    pub data: Vec<ThreadSection>,
    pub next_cursor: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawAppearance {
    icon: Option<String>,
    color: Option<String>,
}

#[derive(Deserialize)]
struct RawSection {
    id: String,
    name: String,
    appearance: Option<RawAppearance>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawPage {
    data: Vec<RawSection>,
    next_cursor: Option<String>,
}

pub(crate) async fn list(
    client: &AppServerClient,
    cursor: Option<String>,
    limit: Option<u32>,
) -> Result<SectionPage, SdkError> {
    let mut params = Map::new();
    if let Some(cursor) = cursor {
        params.insert("cursor".to_owned(), Value::String(cursor));
    }
    if let Some(limit) = limit {
        params.insert("limit".to_owned(), Value::Number(limit.into()));
    }
    let response = client
        .request("threadSection/list", Value::Object(params))
        .await?;
    validate(
        "threadSection/list",
        &response.value,
        codex_app_server_types::validate_thread_section_list_response,
    )?;
    parse_page(response.value)
}

pub(crate) async fn create(
    client: &AppServerClient,
    name: String,
    appearance: Option<SectionAppearance>,
) -> Result<ThreadSection, SdkError> {
    let response = client
        .request(
            "threadSection/create",
            json!({"name": name, "appearance": appearance.map(SectionAppearance::into_value)}),
        )
        .await?;
    validate(
        "threadSection/create",
        &response.value,
        codex_app_server_types::validate_thread_section_create_response,
    )?;
    parse_response_section("threadSection/create", &response.value)
}

pub(crate) async fn update(
    client: &AppServerClient,
    section_id: &str,
    name: String,
    appearance: SectionAppearanceUpdate,
) -> Result<ThreadSection, SdkError> {
    let mut params = Map::from_iter([
        ("sectionId".to_owned(), Value::String(section_id.to_owned())),
        ("name".to_owned(), Value::String(name)),
    ]);
    match appearance {
        SectionAppearanceUpdate::Preserve => {}
        SectionAppearanceUpdate::Clear => {
            params.insert("appearance".to_owned(), Value::Null);
        }
        SectionAppearanceUpdate::Set(appearance) => {
            params.insert("appearance".to_owned(), appearance.into_value());
        }
    }
    let response = client
        .request("threadSection/update", Value::Object(params))
        .await?;
    validate(
        "threadSection/update",
        &response.value,
        codex_app_server_types::validate_thread_section_update_response,
    )?;
    parse_response_section("threadSection/update", &response.value)
}

pub(crate) async fn delete(client: &AppServerClient, section_id: &str) -> Result<(), SdkError> {
    let response = client
        .request("threadSection/delete", json!({"sectionId": section_id}))
        .await?;
    validate(
        "threadSection/delete",
        &response.value,
        codex_app_server_types::validate_thread_section_delete_response,
    )
}

pub(crate) async fn move_thread(
    client: &AppServerClient,
    thread_id: &ThreadId,
    section_id: Option<&str>,
    before_thread_id: Option<&ThreadId>,
) -> Result<(), SdkError> {
    let response = client
        .request(
            "thread/section/move",
            json!({
                "threadId": thread_id.as_str(),
                "sectionId": section_id,
                "beforeThreadId": before_thread_id.map(ThreadId::as_str),
            }),
        )
        .await?;
    validate(
        "thread/section/move",
        &response.value,
        codex_app_server_types::validate_thread_section_move_response,
    )
}

fn parse_page(value: Value) -> Result<SectionPage, SdkError> {
    let raw: RawPage = serde_json::from_value(value)
        .map_err(|error| projection_error("threadSection/list", error.to_string()))?;
    Ok(SectionPage {
        data: raw.data.into_iter().map(project).collect(),
        next_cursor: raw.next_cursor,
    })
}

fn parse_response_section(method: &'static str, value: &Value) -> Result<ThreadSection, SdkError> {
    let raw: RawSection = serde_json::from_value(value.get("section").cloned().ok_or(
        SdkError::MissingResponseField {
            method,
            field: "section",
        },
    )?)
    .map_err(|error| projection_error(method, error.to_string()))?;
    Ok(project(raw))
}

fn project(raw: RawSection) -> ThreadSection {
    ThreadSection {
        id: raw.id,
        name: raw.name,
        appearance: raw.appearance.map(|appearance| SectionAppearance {
            icon: appearance.icon,
            color: appearance.color,
        }),
    }
}

fn validate(
    method: &'static str,
    value: &Value,
    validator: fn(&Value) -> Result<(), serde_json::Error>,
) -> Result<(), SdkError> {
    validator(value).map_err(|error| projection_error(method, error.to_string()))
}

fn projection_error(method: &'static str, message: String) -> SdkError {
    SdkError::ResponseValidation { method, message }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn section_page_projects_appearance_and_cursor() {
        let page = parse_page(json!({
            "data": [{
                "id": "section",
                "name": "Pinned",
                "appearance": {"icon": "star", "color": "orange"}
            }],
            "nextCursor": "next"
        }))
        .expect("section page");
        assert_eq!(page.data[0].name, "Pinned");
        assert_eq!(
            page.data[0]
                .appearance
                .as_ref()
                .and_then(|value| value.icon.as_deref()),
            Some("star")
        );
        assert_eq!(page.next_cursor.as_deref(), Some("next"));
    }
}
