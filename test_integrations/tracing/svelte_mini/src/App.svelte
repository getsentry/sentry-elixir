<script>
  let loading = $state(false);
  let result = $state("");

  async function triggerError() {
    loading = true;
    result = "";
    try {
      const response = await fetch(`${SENTRY_E2E_PHOENIX_APP_URL}/error`, {
        method: "GET",
        headers: {
          "Content-Type": "application/json",
        },
      });

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

  async function fetchData() {
    loading = true;
    result = "";
    try {
      const response = await fetch(`${SENTRY_E2E_PHOENIX_APP_URL}/api/data`, {
        method: "GET",
        headers: {
          "Content-Type": "application/json",
        },
      });

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
