// XDRemux modification: diagnostics replaced by redacted wrapper events.
use crate::http::server::common::error::AppError;
use http_body_util::BodyExt;
use hyper::body::Incoming;
use serde::de::DeserializeOwned;

pub(crate) trait CollectToJson {
    async fn collect_to_json<T: DeserializeOwned>(self) -> Result<T, AppError>;
}

impl CollectToJson for Incoming {
    async fn collect_to_json<T: DeserializeOwned>(self) -> Result<T, AppError> {
        // XDRemux: bound metadata allocation and a stalled metadata request.
        let bytes = tokio::time::timeout(std::time::Duration::from_secs(10),
            http_body_util::Limited::new(self, 1024 * 1024).collect()).await
            .map_err(|_| AppError::Status(hyper::StatusCode::REQUEST_TIMEOUT))?
            .map_err(|_| AppError::Status(hyper::StatusCode::PAYLOAD_TOO_LARGE))?.to_bytes();
        serde_json::from_slice::<T>(&bytes).map_err(|err| {
            ();
            AppError::BadRequest("Invalid JSON body".to_string())
        })
    }
}
