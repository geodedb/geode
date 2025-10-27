//! Connection pooling for Geode connections.

use tokio::sync::Semaphore;
use std::sync::Arc;

use crate::client::Client;
use crate::error::Result;

/// Connection pool
pub struct ConnectionPool {
    client: Client,
    semaphore: Arc<Semaphore>,
}

impl ConnectionPool {
    pub fn new(dsn: &str, max_size: usize) -> Result<Self> {
        Ok(Self {
            client: Client::new(dsn)?,
            semaphore: Arc::new(Semaphore::new(max_size)),
        })
    }

    pub async fn acquire(&self) -> Result<crate::client::Connection> {
        let _permit = self.semaphore.acquire().await;
        self.client.connect().await
    }
}
