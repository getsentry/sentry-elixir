<script>
  import * as Sentry from "@sentry/svelte";

  let loading = $state(false);
  let result = $state("");

  async function makeRequest(method, url, body = undefined) {
    return await Sentry.startSpan(
      { op: "http.client", name: `${method} ${url}` },
      async (span) => {
        const parsedURL = new URL(url, location.origin);

        span.setAttribute("http.request.method", method);
        span.setAttribute("server.address", parsedURL.hostname);
        span.setAttribute("server.port", parsedURL.port || undefined);

        const fetchOptions = {
          method,
          headers: {
            "Content-Type": "application/json",
          },
        };

        if (body !== undefined) {
          fetchOptions.body = JSON.stringify(body);
        }

        const response = await fetch(url, fetchOptions);

        span.setAttribute("http.response.status_code", response.status);
        span.setAttribute(
          "http.response_content_length",
          Number(response.headers.get("content-length"))
        );

        return response;
      }
    );
  }

  async function triggerError() {
    loading = true;
    result = "";
    try {
      const response = await makeRequest("GET", `${SENTRY_E2E_PHOENIX_APP_URL}/error`);

      if (response.ok) {
        const data = await response.json();
        result = `Success: ${JSON.stringify(data)}`;
      } else {
        result = `Error: ${response.status} ${response.statusText}`;
      }
    } catch (error) {
      result = `Error: ${error.message}`;
    } finally {
      loading = false;
    }
  }

  async function scheduleJob() {
    loading = true;
    result = "";
    try {
      const response = await makeRequest("POST", `${SENTRY_E2E_PHOENIX_APP_URL}/api/oban-job`);

      if (response.ok) {
        const data = await response.json();
        result = `Job scheduled: ${JSON.stringify(data, null, 2)}`;
      } else {
        result = `Error: ${response.status} ${response.statusText}`;
      }
    } catch (error) {
      result = `Error: ${error.message}`;
    } finally {
      loading = false;
    }
  }

  async function scheduleGraphQLJob() {
    loading = true;
    result = "";
    try {
      const mutation = `
        mutation ScheduleJob($payload: String!) {
          scheduleJob(payload: $payload) {
            jobId
            worker
            queue
            payload
            enqueued
          }
        }
      `;

      const response = await makeRequest("POST", `${SENTRY_E2E_PHOENIX_APP_URL}/api/graphql`, {
        query: mutation,
        variables: { payload: "e2e-distributed-trace-test" },
      });

      if (response.ok) {
        const data = await response.json();
        result = `GraphQL job scheduled: ${JSON.stringify(data, null, 2)}`;
      } else {
        result = `Error: ${response.status} ${response.statusText}`;
      }
    } catch (error) {
      result = `Error: ${error.message}`;
    } finally {
      loading = false;
    }
  }

  async function fetchData() {
    loading = true;
    result = "";
    try {
      const response = await makeRequest("GET", `${SENTRY_E2E_PHOENIX_APP_URL}/api/data`);

      if (response.ok) {
        const data = await response.json();
        result = `Success: ${JSON.stringify(data, null, 2)}`;
      } else {
        result = `Error: ${response.status} ${response.statusText}`;
      }
    } catch (error) {
      result = `Error: ${error.message}`;
    } finally {
      loading = false;
    }
  }
</script>

<main>
  <h1>Svelte Mini App</h1>
  <p>
    Test distributed tracing between frontend and backend:
  </p>

  <div class="button-group">
    <button id="fetch-data-btn" onclick={fetchData} disabled={loading}>
      {loading ? "Loading..." : "Fetch Data"}
    </button>

    <button id="trigger-error-btn" onclick={triggerError} disabled={loading}>
      {loading ? "Loading..." : "Trigger Error"}
    </button>

    <button id="schedule-job-btn" onclick={scheduleJob} disabled={loading}>
      {loading ? "Loading..." : "Schedule Job"}
    </button>

    <button id="schedule-graphql-job-btn" onclick={scheduleGraphQLJob} disabled={loading}>
      {loading ? "Loading..." : "Schedule GraphQL Job"}
    </button>
  </div>

  {#if result}
    <div class="result">
      <h3>Result:</h3>
      <pre>{result}</pre>
    </div>
  {/if}
</main>

<style>
  main {
    text-align: center;
    padding: 1em;
    max-width: 480px;
    margin: 0 auto;
  }

  .button-group {
    display: flex;
    gap: 10px;
    justify-content: center;
    margin: 20px 0;
  }

  button {
    background-color: #ff3e00;
    color: white;
    border: none;
    padding: 10px 20px;
    border-radius: 5px;
    cursor: pointer;
    font-size: 16px;
  }

  button:disabled {
    background-color: #ccc;
    cursor: not-allowed;
  }

  button#fetch-data-btn {
    background-color: #4CAF50;
  }

  button#fetch-data-btn:disabled {
    background-color: #ccc;
  }

  .result {
    margin-top: 20px;
    text-align: left;
    background-color: #f5f5f5;
    padding: 10px;
    border-radius: 5px;
  }

  pre {
    white-space: pre-wrap;
    word-break: break-word;
  }
</style>
