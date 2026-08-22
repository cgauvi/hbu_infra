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

# The first rule in this file is no longer `help` — an order-only prerequisite
# line counts as a rule, and inheriting the default goal from whichever one
# sorts first is how `make` on its own ends up running terraform.
.DEFAULT_GOAL := help

# The stack lives in account 038083667790. The default profile is a different
# account entirely, where none of these resources exist — and because BUCKET is
# derived below rather than committed, running under it does not fail loudly, it
# just points every target at a bucket and a parameter namespace that are not
# there. Pinned and exported so terraform, the aws CLI, and scripts/db.py all
# resolve the same account. Override on the command line if that ever changes.
#
# `?=` alone would not be enough: a variable exported empty still counts as
# defined, so a shell carrying AWS_PROFILE= leaves the pin blank and everything
# silently falls through to the default profile. Test the value, not whether it
# is set.
ifeq (,$(strip $(AWS_PROFILE)))
AWS_PROFILE := charles_gauvin_east_1
endif
export AWS_PROFILE

# Which account those credentials have to land in. aws-check below enforces it,
# so a profile that points somewhere else — or whose keys have been rotated out
# from under it — fails on the first line instead of as an AccessDenied three
# steps in.
AWS_ACCOUNT ?= 038083667790

# botocore reads AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY *before* it looks at
# AWS_PROFILE, so a stray pair left in the shell outranks the pin above and
# every target quietly runs as whoever those keys belong to. Drop them from the
# environment make hands to $(shell) and to recipes. AWS_USE_ENV_CREDS=1 opts
# back in, for CI that has no credentials file to name a profile in.
ifneq (1,$(AWS_USE_ENV_CREDS))
unexport AWS_ACCESS_KEY_ID
unexport AWS_SECRET_ACCESS_KEY
unexport AWS_SESSION_TOKEN
endif

# A TLS-inspecting proxy (Zscaler here) reissues every certificate under a root
# that only the host trust store carries. Linux picks it up — openssl and
# terraform verify fine — but botocore and the aws CLI ship their own CA bundle
# and never look at /etc/ssl, so from WSL every AWS call dies with
# CERTIFICATE_VERIFY_FAILED while the same profile works from Windows. Worse
# than a bad error message: ACCOUNT_ID below is a $(shell ...), so the failure
# leaves BUCKET pointing at hbu-tf-state- and terraform init fails on that
# instead. Hand them the system bundle, which is a superset of the public roots,
# so this is a no-op where no proxy is in the way. Empty on Windows, whose
# stores the CLI already reads; exported only when non-empty, since an empty
# AWS_CA_BUNDLE counts as set and is worse than none.
ifeq (,$(strip $(AWS_CA_BUNDLE)))
AWS_CA_BUNDLE := $(wildcard /etc/ssl/certs/ca-certificates.crt)
endif
ifneq (,$(strip $(AWS_CA_BUNDLE)))
export AWS_CA_BUNDLE
endif

# Derived from whichever credentials are active, so the backend never has to be
# committed and switching AWS_PROFILE switches accounts cleanly.
# `export` above reaches recipes but not $(shell), so name the profile inline
# here too, along with the CA bundle for the same reason — otherwise BUCKET
# silently resolves against the default account, or against nothing at all.
ACCOUNT_ID = $(shell AWS_PROFILE=$(AWS_PROFILE) $(if $(AWS_CA_BUNDLE),AWS_CA_BUNDLE=$(AWS_CA_BUNDLE)) aws sts get-caller-identity --query Account --output text)
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

# A native Windows uv launched from msys2's sh can inherit no TMP at all, fall
# back to C:\WINDOWS and die with "Access is denied"; cygpath gives it a real
# one. No-op on Linux and on any shell that already sets TMP.
ifeq (,$(TMP))
ifneq (,$(findstring NT,$(shell uname -s)))
export TMP  := $(shell cygpath -w /tmp 2>/dev/null)
export TEMP := $(TMP)
endif
endif

# The uv installer drops its binary in ~/.local/bin and does not touch this
# shell's PATH, so put it on ours: uv-check can install uv and use it in one run.
export PATH := $(HOME)/.local/bin:$(PATH)

UV   ?= uv
# A venv bakes in its layout (bin/python vs Scripts/python.exe) and the
# absolute path of the interpreter that built it, so one directory cannot
# serve both kernels — whichever shell ran db-deps last would own it. Linux,
# WSL included, keeps the plain name; a native Windows shell gets its own.
ifeq (Linux,$(shell uname -s 2>/dev/null))
VENV ?= .venv
# The same interop that makes a Windows uv reachable from WSL (see uv-check)
# also makes Scripts/python.exe runnable here — silently, since [ -x ] says yes
# and it starts fine. But it starts as a *Windows* process, and WSLENV forwards
# none of our exports across that boundary: AWS_PROFILE arrives unset, botocore
# falls back to the default profile, and aws-check reports the wrong account for
# a profile that is in fact pinned correctly. So under Linux, a venv is a venv
# only if it has bin/python.
PY_NAMES := bin/python
else
VENV ?= .venv-win
PY_NAMES := Scripts/python.exe bin/python.exe bin/python
endif
# An already-active venv wins over the project one. Which name the interpreter
# has depends on the platform (bin/python, Scripts/python.exe), so probe for it
# when a recipe runs rather than when this file is read — db-deps is usually
# what creates the venv in the first place. Falling back to the first candidate
# keeps the value non-empty, which is what makes the [ -x ] guards in recipes
# choose their CLI path instead of running an empty command.
PY = $$(V="$${VIRTUAL_ENV:-$(VENV)}"; for p in $(PY_NAMES); do [ -e "$$V/$$p" ] && { echo "$$V/$$p"; exit; }; done; echo "$$V/$(firstword $(PY_NAMES))")

DB = $(PY) scripts/db.py --env $(ENV) --region $(AWS_REGION) $(if $(TUNNEL),--tunnel $(LOCAL_PORT))

.PHONY: help aws-check bootstrap init-shared plan-shared apply-shared destroy-shared \
        init plan apply destroy fmt validate output \
        db-deps uv-check db-init db-check db-shell db-url db-env db-query db-wait \
        db-start db-stop db-tunnel

help:
	@grep -E '^[a-z-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# Order-only so a failure stops the run before anything touches AWS, and so the
# check runs once per invocation no matter how many of these are named.
bootstrap init-shared plan-shared apply-shared destroy-shared \
init plan apply destroy validate output: | aws-check
db-init db-bootstrap db-ca db-check db-shell db-url db-env db-app-env \
db-query db-wait db-start db-stop db-tunnel: | aws-check

# Every target that talks to AWS goes through here first. Without it the wrong
# credentials are invisible: BUCKET and the /$(PROJECT)-$(ENV) parameter
# namespace both resolve against whatever account is actually active, so the
# first sign of trouble is an AccessDenied on a resource that exists perfectly
# well one account over.
#
# Asked of boto3 rather than the aws CLI whenever the venv has it, because boto3
# is what scripts/db.py resolves credentials through — a check that agrees with
# the CLI but not with the SDK would pass and then fail. The CLI is the fallback
# for terraform targets that run before any venv exists; under msys it is also
# the more fragile of the two, so what answered is named in the failure.
# Messages go to stderr so `eval "$$(make -s db-env)"` keeps working.
aws-check: ## Fail unless the active credentials belong to AWS_ACCOUNT
	@p=$(PY); via="the aws CLI"; \
	if [ -x "$$p" ] && "$$p" -c "import boto3" 2>/dev/null; then \
	  via="boto3 ($$p)"; \
	  id=$$("$$p" -c "import boto3;print(boto3.client('sts',region_name='$(AWS_REGION)').get_caller_identity()['Account'])" 2>&1 | tail -1); \
	else \
	  id=$$(aws sts get-caller-identity --query Account --output text 2>&1 | tail -1); \
	fi; \
	case "$$id" in \
	  $(AWS_ACCOUNT)) : ;; \
	  [0-9]*) \
	    echo "wrong AWS account: AWS_PROFILE=$${AWS_PROFILE:-<unset>} resolves to $$id," >&2; \
	    echo "  but this stack lives in $(AWS_ACCOUNT). Point that profile at working" >&2; \
	    echo "  keys in ~/.aws/credentials, or pass AWS_ACCOUNT=$$id to target $$id." >&2; \
	    exit 1 ;; \
	  *) \
	    echo "could not resolve AWS credentials for AWS_PROFILE=$${AWS_PROFILE:-<unset>}," >&2; \
	    echo "  asking $$via:" >&2; \
	    echo "  $$id" >&2; \
	    exit 1 ;; \
	esac

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
# So uv is the only installer this target trusts: when uv is missing we install
# uv itself instead of falling back to a pip that may not exist.
db-deps: | uv-check ## Install what scripts/db.py needs (boto3, psycopg)
	@[ -n "$$VIRTUAL_ENV" ] || $(UV) venv --allow-existing "$(VENV)"
	$(UV) pip install --python "$${VIRTUAL_ENV:-$(VENV)}" -r scripts/requirements.txt
	@echo "installed into $${VIRTUAL_ENV:-$(VENV)}"

# uname, not $(OS): msys2 make does not pass Windows' OS through. And on WSL,
# interop puts C:\...\uv.exe within reach — a Windows uv builds a Windows venv
# no matter which kernel launched it, so under Linux a uv living on /mnt does
# not count as found.
uv-check:
	@u=$$(command -v $(UV) 2>/dev/null); \
	case "$$(uname -s 2>/dev/null):$$u" in Linux*:/mnt/*|Linux*:*.exe) \
	  echo "ignoring Windows $$u — this shell needs a Linux uv"; u= ;; \
	esac; \
	[ -n "$$u" ] && exit 0; \
	echo "uv not found — installing from astral.sh"; \
	case "$$(uname -s 2>/dev/null)" in \
	  MINGW*|MSYS*|CYGWIN*) powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://astral.sh/uv/install.ps1 | iex" ;; \
	  *) curl -LsSf https://astral.sh/uv/install.sh | sh ;; \
	esac; \
	command -v $(UV) >/dev/null 2>&1 || { \
	  echo "uv installed but not on this PATH — open a new shell and re-run"; exit 1; \
	}

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
