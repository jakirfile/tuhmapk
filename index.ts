export type GitHubContentFile = {
  path: string;
  sha: string;
  content: string;
};

type GitHubContentsResponse = {
  content?: string;
  encoding?: string;
  path?: string;
  sha?: string;
  message?: string;
};

function githubHeaders(token: string): Record<string, string> {
  const normalizedToken = token.trim();
  if (!normalizedToken) {
    throw new Error("A GitHub access token is required.");
  }

  return {
    Accept: "application/vnd.github+json",
    Authorization: `Bearer ${normalizedToken}`,
    "User-Agent": "AllApp-GitHub-Contents-Client",
    "X-GitHub-Api-Version": "2022-11-28",
  };
}

function githubContentsUrl(
  owner: string,
  repository: string,
  path: string,
  branch = "main",
): URL {
  const normalizedOwner = owner.trim();
  const normalizedRepository = repository.trim();
  const pathSegments = path.split("/").filter(Boolean);
  const normalizedBranch = branch.trim();

  if (!/^[A-Za-z0-9-]+$/.test(normalizedOwner)) {
    throw new Error("Invalid GitHub repository owner.");
  }
  if (!/^[A-Za-z0-9_.-]+$/.test(normalizedRepository)) {
    throw new Error("Invalid GitHub repository name.");
  }
  if (pathSegments.length === 0 || pathSegments.some((segment) =>
    segment === "." || segment === ".."
  )) {
    throw new Error("A valid GitHub file path is required.");
  }
  if (!normalizedBranch) {
    throw new Error("A GitHub branch name is required.");
  }

  const encodedPath = pathSegments.map(encodeURIComponent).join("/");
  const url = new URL(
    `https://api.github.com/repos/${normalizedOwner}/${normalizedRepository}/contents/${encodedPath}`,
  );
  url.searchParams.set("ref", normalizedBranch);
  return url;
}

async function readResponseError(response: Response): Promise<string> {
  try {
    const body: unknown = await response.json();
    if (typeof body === "object" && body !== null && "message" in body) {
      const message = body.message;
      if (typeof message === "string" && message.trim()) return message;
    }
  } catch {
    // Fall back to the HTTP status when GitHub does not return JSON.
  }
  return `GitHub API request failed (HTTP ${response.status}).`;
}

function decodeBase64Utf8(value: string): string {
  const binary = atob(value.replace(/\s/g, ""));
  const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
  return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
}

export async function readGitHubFile(
  owner: string,
  repository: string,
  path: string,
  token: string,
  branch = "main",
): Promise<GitHubContentFile> {
  const response = await fetch(githubContentsUrl(owner, repository, path, branch), {
    headers: githubHeaders(token),
  });
  if (!response.ok) {
    throw new Error(await readResponseError(response));
  }

  const payload: GitHubContentsResponse = await response.json();
  if (
    typeof payload.path !== "string" ||
    typeof payload.sha !== "string" ||
    typeof payload.content !== "string" ||
    payload.encoding !== "base64"
  ) {
    throw new Error("GitHub returned an unsupported file response.");
  }

  return {
    path: payload.path,
    sha: payload.sha,
    content: decodeBase64Utf8(payload.content),
  };
}

export async function updateGitHubFile(
  owner: string,
  repository: string,
  path: string,
  token: string,
  sha: string,
  content: string,
  message: string,
  branch = "main",
): Promise<{ path: string; sha: string }> {
  if (!sha.trim()) {
    throw new Error("The current GitHub file SHA is required to update a file.");
  }
  if (!message.trim()) {
    throw new Error("A GitHub commit message is required.");
  }

  const encodedContent = btoa(
    Array.from(new TextEncoder().encode(content), (byte) =>
      String.fromCharCode(byte)
    ).join(""),
  );
  const response = await fetch(githubContentsUrl(owner, repository, path, branch), {
    method: "PUT",
    headers: {
      ...githubHeaders(token),
      "Content-Type": "application/json; charset=utf-8",
    },
    body: JSON.stringify({
      message: message.trim(),
      content: encodedContent,
      sha: sha.trim(),
      branch: branch.trim(),
    }),
  });
  if (!response.ok) {
    throw new Error(await readResponseError(response));
  }

  const payload: {
    content?: { path?: unknown; sha?: unknown };
  } = await response.json();
  const updatedPath = payload.content?.path;
  const updatedSha = payload.content?.sha;
  if (typeof updatedPath !== "string" || typeof updatedSha !== "string") {
    throw new Error("GitHub did not confirm the updated file revision.");
  }
  return { path: updatedPath, sha: updatedSha };
}
