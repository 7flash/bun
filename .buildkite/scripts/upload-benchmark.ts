import { getCommit, getSecret } from "../../scripts/utils.mjs";

await fetch(getSecret("BENCHMARK_URL"), {
  method: "POST",
  body: JSON.stringify({
    tag: "_",
    commit: getCommit(),
    artifact_url: "_",
  }),
});
