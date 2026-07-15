terraform {
  required_version = ">= 1.6"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }

  # Local state, deliberately. A remote backend means a paid bucket or a paid TF Cloud seat, and
  # Haven's cost mandate is $0 recurring beyond the $99/yr Apple fee (docs/OPERATING-COSTS.md).
  # One operator, one namespace — a state file on disk is the honest fit.
  # State is gitignored: it holds the account id in plaintext.
}

# Auth comes from CLOUDFLARE_API_TOKEN in the environment, never from a committed file.
provider "cloudflare" {}
