# CIVIT_Download.sh

Download one or more Civitai model files without exposing the API token in command arguments.

## Requirements
- `curl`
- An interactive terminal or an already-open file descriptor containing the token

## Usage
```bash
read -r -s -p "Civitai token: " token
CIVIT_API_FD=9 ./CIVIT_Download.sh <URL1> [URL2] ... 9<<<"$token"
unset token
```

## Notes
- Each URL is fetched with a Bearer token header.
- Output filenames are determined by the server via `-J -O`.
- Shell tracing is disabled, and the token is sent to `curl` through standard input rather than its argument list.
