use codex_app_server_client::AppServerClient;
use serde_json::{Value, json};

use crate::SdkError;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AccountKind {
    ApiKey,
    ChatGpt {
        email: Option<String>,
        plan_type: String,
    },
    AmazonBedrock {
        uses_codex_managed_credentials: bool,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AccountSnapshot {
    pub account: Option<AccountKind>,
    pub requires_openai_auth: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LoginAppBrand {
    Codex,
    ChatGpt,
}

impl LoginAppBrand {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Codex => "codex",
            Self::ChatGpt => "chatgpt",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum LoginRequest {
    ApiKey(String),
    ChatGptBrowser {
        streamlined: bool,
        hosted_success_page: bool,
        app_brand: Option<LoginAppBrand>,
    },
    ChatGptDeviceCode,
    AmazonBedrock {
        api_key: String,
        region: String,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum LoginChallenge {
    Complete,
    Browser {
        login_id: String,
        auth_url: String,
    },
    DeviceCode {
        login_id: String,
        user_code: String,
        verification_url: String,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CancelLoginStatus {
    Canceled,
    NotFound,
}

pub(crate) async fn read(
    client: &AppServerClient,
    refresh_token: bool,
) -> Result<AccountSnapshot, SdkError> {
    let response = client
        .request("account/read", json!({"refreshToken": refresh_token}))
        .await?;
    validate(
        "account/read",
        &response.value,
        codex_app_server_types::validate_account_read_response,
    )?;
    let account = response
        .value
        .get("account")
        .filter(|value| !value.is_null());
    Ok(AccountSnapshot {
        account: account.map(parse_account).transpose()?,
        requires_openai_auth: response
            .value
            .get("requiresOpenaiAuth")
            .and_then(Value::as_bool)
            .ok_or(SdkError::MissingResponseField {
                method: "account/read",
                field: "requiresOpenaiAuth",
            })?,
    })
}

pub(crate) async fn login(
    client: &AppServerClient,
    request: LoginRequest,
) -> Result<LoginChallenge, SdkError> {
    let params = match request {
        LoginRequest::ApiKey(api_key) => json!({"type": "apiKey", "apiKey": api_key}),
        LoginRequest::ChatGptBrowser {
            streamlined,
            hosted_success_page,
            app_brand,
        } => json!({
            "type": "chatgpt",
            "codexStreamlinedLogin": streamlined,
            "useHostedLoginSuccessPage": hosted_success_page,
            "appBrand": app_brand.map(LoginAppBrand::as_str),
        }),
        LoginRequest::ChatGptDeviceCode => json!({"type": "chatgptDeviceCode"}),
        LoginRequest::AmazonBedrock { api_key, region } => {
            json!({"type": "amazonBedrock", "apiKey": api_key, "region": region})
        }
    };
    let response = client.request("account/login/start", params).await?;
    validate(
        "account/login/start",
        &response.value,
        codex_app_server_types::validate_account_login_response,
    )?;
    parse_login_challenge(&response.value)
}

pub(crate) async fn cancel(
    client: &AppServerClient,
    login_id: &str,
) -> Result<CancelLoginStatus, SdkError> {
    let response = client
        .request("account/login/cancel", json!({"loginId": login_id}))
        .await?;
    validate(
        "account/login/cancel",
        &response.value,
        codex_app_server_types::validate_account_login_cancel_response,
    )?;
    match response.value.get("status").and_then(Value::as_str) {
        Some("canceled") => Ok(CancelLoginStatus::Canceled),
        Some("notFound") => Ok(CancelLoginStatus::NotFound),
        _ => Err(projection_error(
            "account/login/cancel",
            "invalid cancellation status",
        )),
    }
}

pub(crate) async fn logout(client: &AppServerClient) -> Result<(), SdkError> {
    let response = client.request("account/logout", json!({})).await?;
    validate(
        "account/logout",
        &response.value,
        codex_app_server_types::validate_account_logout_response,
    )
}

fn parse_account(value: &Value) -> Result<AccountKind, SdkError> {
    match value.get("type").and_then(Value::as_str) {
        Some("apiKey") => Ok(AccountKind::ApiKey),
        Some("chatgpt") => Ok(AccountKind::ChatGpt {
            email: value
                .get("email")
                .and_then(Value::as_str)
                .map(str::to_owned),
            plan_type: value
                .get("planType")
                .and_then(Value::as_str)
                .ok_or_else(|| projection_error("account/read", "missing ChatGPT plan type"))?
                .to_owned(),
        }),
        Some("amazonBedrock") => Ok(AccountKind::AmazonBedrock {
            uses_codex_managed_credentials: value
                .get("usesCodexManagedCredentials")
                .and_then(Value::as_bool)
                .unwrap_or(false),
        }),
        _ => Err(projection_error("account/read", "invalid account type")),
    }
}

fn parse_login_challenge(value: &Value) -> Result<LoginChallenge, SdkError> {
    match value.get("type").and_then(Value::as_str) {
        Some("apiKey" | "chatgptAuthTokens" | "amazonBedrock") => Ok(LoginChallenge::Complete),
        Some("chatgpt") => Ok(LoginChallenge::Browser {
            login_id: required_string(value, "loginId")?,
            auth_url: required_string(value, "authUrl")?,
        }),
        Some("chatgptDeviceCode") => Ok(LoginChallenge::DeviceCode {
            login_id: required_string(value, "loginId")?,
            user_code: required_string(value, "userCode")?,
            verification_url: required_string(value, "verificationUrl")?,
        }),
        _ => Err(projection_error(
            "account/login/start",
            "invalid login response type",
        )),
    }
}

fn required_string(value: &Value, field: &'static str) -> Result<String, SdkError> {
    value
        .get(field)
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or(SdkError::MissingResponseField {
            method: "account/login/start",
            field,
        })
}

fn validate(
    method: &'static str,
    value: &Value,
    validator: fn(&Value) -> Result<(), serde_json::Error>,
) -> Result<(), SdkError> {
    validator(value).map_err(|error| projection_error(method, &error.to_string()))
}

fn projection_error(method: &'static str, message: &str) -> SdkError {
    SdkError::ResponseValidation {
        method,
        message: message.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_device_code_without_losing_login_identity() {
        assert_eq!(
            parse_login_challenge(&json!({
                "type": "chatgptDeviceCode",
                "loginId": "login",
                "userCode": "ABCD-EFGH",
                "verificationUrl": "https://example.com/device"
            }))
            .expect("device challenge"),
            LoginChallenge::DeviceCode {
                login_id: "login".to_owned(),
                user_code: "ABCD-EFGH".to_owned(),
                verification_url: "https://example.com/device".to_owned(),
            }
        );
    }
}
