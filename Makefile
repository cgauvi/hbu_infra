# hbu_infra — Terraform + database operations
#
#   # one-time, in order:
#   make bootstrap                  # state bucket + lock table (local state)
#   make apply-shared               # VPC, subnets, DB subnet groups
#   make apply       ENV=dev        # RDS, security group, SSM contract
#   make db-bootstrap ENV=dev       # urban_rag role + grants + its password
#   make db-init     ENV=dev        # postgis + pgvector + rag schema
#
#   # day to day:
#   make db-shell    ENV=dev        # interactive SQL
#   make db-check    ENV=dev        # what is installed and loaded
#   make db-url      ENV=dev        # connection URL for anything else
#   make plan        ENV=dev

ENV        ?= dev
AWS_REGION ?= us-east-1
PROJECT    ?= hbu

# The stack lives in account 038083667790. The default profile is a different
# account entirely, where none of these resources exist — and because BUCKET is
# derived below rather than committed, running under it does not fail loudly, it
# just points every target at a bucket and a parameter namespace that are not
# there. Pinned and exported so terraform, the aws CLI, and scripts/db.py all
# resolve the same account. Override on the command line if that ever changes.
AWS_PROFILE ?= charles_gauvin_east_1
export AWS_PROFILE

# Derived from whichever credentials are active, so the backend never has to be
# committed and switching AWS_PROFILE switches accounts cleanly.
# `export` above reaches recipes but not $(shell), so name the profile inline
# here too — otherwise BUCKET silently resolves against the default account.
ACCOUNT_ID = $(shell AWS_PROFILE=$(AWS_PROFILE) aws sts get-caller-identity --query Account --output text)
BUCKET     = $(PROJECT)-tf-state-$(ACCOUNT_ID)
LOCK_TABLE = $(PROJECT)-tf-locks

TF        = terraform
TF_SHARED = terraform -chdir=shared
TF_BOOT   = terraform -chdir=bootstrap

TF_BACKEND = -backend-config="bucket=$(BUCKET)" \
             -backend-config="key=$(PROJECT)/$(ENV)/terraform.tfstate" \
             -backend-config="dynamodb_table=$(LOCK_TABLE)" \
             -backend-config="encrypt=true"

TF_BACKEND_SHARED = -backend-config="bucket=$(BUCKET)" \
                    -backend-config="key=$(PROJECT)/shared/terraform.tfstate" \
                    -backend-config="dynamodb_table=$(LOCK_TABLE)" \
                    -backend-config="encrypt=true"

TF_VARS = -var-file="$(ENV).tfvars"

# With no public endpoint there is no route from a laptop to the instance, so
# every db-* target can be pointed at an open `make db-tunnel` session instead:
#
#   make db-tunnel ENV=dev              # one shell, left running
#   make db-check  ENV=dev TUNNEL=1     # another
#
# Only the address is swapped; the credentials still come from AWS.
LOCAL_PORT ?= 5433
TUNNEL     ?=

DB = ./scripts/db.py --env $(ENV) --region $(AWS_REGION) $(if $(TUNNEL),--tunnel $(LOCAL_PORT))

.PHONY: help bootstrap init-shared plan-shared apply-shared destroy-shared \
        init plan apply destroy fmt validate output \
        db-deps db-init db-check db-shell db-url db-env db-query db-wait \
        db-start db-stop db-tunnel

help:
	@grep -E '^[a-z-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------------------
# Terraform
# ---------------------------------------------------------------------------

bootstrap: ## Create the state bucket and lock table (local state, run once)
	$(TF_BOOT) init
	$(TF_BOOT) apply

init-shared: ## terraform init for the shared VPC stack
	$(TF_SHARED) init -reconfigure $(TF_BACKEND_SHARED)

plan-shared: init-shared ## Plan the shared VPC stack
	$(TF_SHARED) plan -out=tfplan

apply-shared: ## Apply the shared VPC stack (run plan-shared first)
	$(TF_SHARED) apply tfplan && rm -f shared/tfplan

# Only safe once every per-env stack is gone: their remote_state lookups fail
# without the shared outputs.
destroy-shared: init-shared ## Destroy the shared VPC stack
	$(TF_SHARED) destroy

init: ## terraform init for ENV
	$(TF) init -reconfigure $(TF_BACKEND)

plan: init ## Plan ENV
	$(TF) plan $(TF_VARS) -out=tfplan

apply: ## Apply ENV (run plan first)
	$(TF) apply tfplan && rm -f tfplan

destroy: init ## Destroy ENV
	$(TF) destroy $(TF_VARS)

fmt: ## Rewrite all .tf files to canonical format
	$(TF) fmt -recursive .

validate: init ## Validate the per-env configuration
	$(TF) validate

output: ## Show ENV outputs
	$(TF) output

# ---------------------------------------------------------------------------
# Database
#
# Every target below resolves the endpoint and password from SSM and Secrets
# Manager at call time, so none of them take a host or a password argument and
# none of them break when the instance is replaced.
# ---------------------------------------------------------------------------

# A uv-created venv — which the dataplatform's is, and which is usually what is
# active here — ships without pip, and a stock Ubuntu python3 has none either.
# So reach for uv first and keep pip as the fallback.
db-deps: ## Install what scripts/db.py needs (boto3, psycopg)
	@if command -v uv >/dev/null 2>&1; then \
		uv pip install -r scripts/requirements.txt; \
	elif python3 -m pip --version >/dev/null 2>&1; then \
		python3 -m pip install -r scripts/requirements.txt; \
	else \
		echo "Need uv or pip. Install uv (https://docs.astral.sh/uv/) or apt install python3-pip."; \
		exit 1; \
	fi

db-init: ## Apply sql/*.sql — roles, extensions, rag.features, rag.lots, spatial search
	$(DB) init

# sql/000_roles.sql is applied by db-init too, since it sorts first. What only
# this target does is the credential no .sql file carries: generate the role's
# password, set it, and write it to the secret Terraform created for it.
db-bootstrap: ## Create the urban_rag role + grants, storing its password in Secrets Manager
	$(DB) bootstrap --store-password

db-ca: ## Download the RDS root certificate that sslmode=verify-full needs
	$(DB) ca

db-check: ## Report extensions, tables, and what is loaded
	$(DB) check

db-shell: ## Interactive SQL (psql when installed, built-in REPL otherwise)
	$(DB) shell

db-url: ## Print the connection URL
	$(DB) url

db-env: ## Master-user exports — use as: eval "$$(make -s db-env)"
	@$(DB) env

db-app-env: ## Pipeline-role exports (URBAN_RAG_PG_*, password via Secrets Manager)
	@$(DB) env --app

db-query: ## Run one statement: make db-query SQL="select 1"
	$(DB) query "$(SQL)"

db-wait: ## Block until the instance accepts connections
	$(DB) wait

db-start: ## Start a stopped instance
	$(DB) start

db-stop: ## Stop the instance
	$(DB) stop

# Only for a database with no public endpoint. Leaves psql-able postgres on
# localhost:$(LOCAL_PORT) for as long as the session is open.
db-tunnel: ## Port-forward through the SSM bastion to localhost:$(LOCAL_PORT)
	./scripts/tunnel.sh $(ENV) $(LOCAL_PORT) $(AWS_REGION)
