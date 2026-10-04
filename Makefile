# hbu_infra — Terraform + database operations
#
#   # one-time, in order:
#   make bootstrap                  # state bucket + lock table (local state)
#   make apply-shared               # VPC, subnets, DB subnet groups, ECR repo
#   make apply       ENV=dev        # RDS, security group, SSM contract
#   make db-bootstrap ENV=dev       # urban_rag role + grants + its password
#   make db-init     ENV=dev        # postgis + pgvector + rag/silver/gold schemas
#
#   # then the web app, in this order — the service cannot start against a
#   # tag that is not in ECR yet:
#   make app-push     ENV=dev       # build ../hbu_rag_map, push :latest
#   make app-password ENV=dev       # the shared password people log in with
#   make app-hf-token ENV=dev       # the Inference API token
#   make app-mapbox-token ENV=dev   # the Mapbox basemap token (optional; OSM without it)
#   make plan apply   ENV=dev       # with enable_app = true in dev.tfvars
#   make app-url      ENV=dev       # where it ended up
#   make app-dns      ENV=dev       # the record to point a domain at it
#
#   # day to day:
#   make db-shell    ENV=dev        # interactive SQL
#   make db-check    ENV=dev        # what is installed and loaded
#   make db-url      ENV=dev        # connection URL for anything else
#   make plan        ENV=dev
#   make app-push app-deploy ENV=dev  # ship a code change
#   make app-logs    ENV=dev        # tail the container
#
#   # moving the data off AWS first — see "Moving the database off AWS" in the
#   # README. The dump is the artifact that travels: to the local container,
#   # to S3, to another machine.
#   make db-dump-remote ENV=dev     # pg_dump on the bastion -> S3 -> backups/
#   make db-restore-local           # ...into hbu_rag_map's local container
#   make db-dump-pull               # (any other machine: newest dump from S3)
#
#   # the tunnel-only variants, for when the bastion is already gone — slow:
#   make db-tunnel ENV=dev          # one shell, left running
#   make db-dump   ENV=dev TUNNEL=1 # another; db-dump-push sends it to S3
#
#   # taking it down a part at a time (each waits for its name typed back):
#   make destroy-app     ENV=dev    # the ALB + Fargate service — most of the bill
#   make destroy-bastion ENV=dev    # the jump host — severs db-* to a private DB
#   make destroy-db      ENV=dev    # the RDS instance and everything in it
#
#   # taking it all down again, in this order:
#   make destroy-all                # every env stack, then the shared one
#   make destroy-bootstrap          # ...and the state backend that held them

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
# so this is a no-op where no proxy is in the way. Exported only when non-empty,
# since an empty AWS_CA_BUNDLE counts as set and is worse than none.
#
# This used to say Windows needed none of it, "whose stores the CLI already
# reads". It does not: AWS CLI v2 bundles its own Python and its own CA list on
# Windows exactly as on Linux, so from Git Bash `aws sts get-caller-identity`
# fails the same way — and because that is what aws-check asks, every target
# here reported the proxy as *missing credentials* and stopped before running.
# There is no /etc/ssl/certs under msys, so name the combined corporate+certifi
# bundle as a second candidate; first readable one wins.
#
# The Windows home has to come from cygpath rather than from $(HOME) or
# $(USERPROFILE): make is an msys2 binary from a different installation than the
# shell that invokes it, so $(HOME) can be /home/<user> — a path with no .certs
# in it — while USERPROFILE may not survive into make at all. `cygpath -D` is
# answered by the msys runtime itself and is right in both, and -m returns the
# Windows form the CLI wants.
WIN_HOME := $(if $(findstring NT,$(shell uname -s)),$(patsubst %/Desktop,%,$(shell cygpath -m -D 2>/dev/null)))
AWS_CA_BUNDLE_CANDIDATES := /etc/ssl/certs/ca-certificates.crt \
                            $(if $(WIN_HOME),$(WIN_HOME)/.certs/zscaler-plus-certifi.pem) \
                            $(HOME)/.certs/zscaler-plus-certifi.pem
ifeq (,$(strip $(AWS_CA_BUNDLE)))
AWS_CA_BUNDLE := $(firstword $(wildcard $(AWS_CA_BUNDLE_CANDIDATES)))
endif
ifneq (,$(strip $(AWS_CA_BUNDLE)))
export AWS_CA_BUNDLE
endif

# And the same absence breaks the CLI outright, not just its trust store. AWS
# CLI v2 imports awscli/telemetry.py at startup, which calls pathlib.Path.home()
# at module scope; on Windows that reads USERPROFILE, then HOMEDRIVE+HOMEPATH,
# and msys2 make forwards none of the three — only a POSIX $(HOME) of
# /home/<user> that a Windows binary cannot use. So aws.exe dies with
#
#     RuntimeError: Could not determine home directory.
#     [PYI-...:ERROR] Failed to execute script 'aws' due to unhandled exception!
#
# before it parses an argument — and since aws-check keeps only the last line
# of that traceback, every target reports working credentials as unresolvable.
# Older CLI builds had no telemetry module and survived, so this arrives with a
# CLI upgrade rather than with any change here. Terraform needs it too: the AWS
# provider finds ~/.aws through Go's os.UserHomeDir(), which on Windows reads
# USERPROFILE and nothing else, so without this the backend authenticates as
# nobody and ACCOUNT_ID below comes back empty.
ifneq (,$(WIN_HOME))
export USERPROFILE := $(WIN_HOME)
endif

# `export` above reaches recipes but not $(shell) — confirmed on make 4.3: a
# recipe sees the exported value, the shell function sees an empty string. So
# every $(shell) that talks to AWS has to carry the profile and the CA bundle
# itself. Named once here rather than inlined, because forgetting it does not
# look like a credentials error at the call site: the command runs as whatever
# the *default* profile is, which is a different account, and comes back with a
# 403 or an empty result that the caller then misreports as missing state.
AWS_SHELL_ENV = AWS_PROFILE=$(AWS_PROFILE) $(if $(AWS_CA_BUNDLE),AWS_CA_BUNDLE=$(AWS_CA_BUNDLE)) \
                $(if $(WIN_HOME),USERPROFILE=$(WIN_HOME))

# Derived from whichever credentials are active, so the backend never has to be
# committed and switching AWS_PROFILE switches accounts cleanly. Without the
# prefix BUCKET silently resolves against the default account, or against
# nothing at all.
ACCOUNT_ID = $(shell $(AWS_SHELL_ENV) aws sts get-caller-identity --query Account --output text)
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

# The address var.allow_current_ip lets through. One curl instead of the
# hashicorp/http provider, which a TLS-inspecting proxy blocks outright —
# Zscaler answers releases.hashicorp.com/terraform-provider-http with a block
# page, and `terraform init` then fails for every environment, including the
# ones that have this feature turned off. Recursive `=`, not `:=`, so the
# lookup happens only in the recipes that expand TF_VARS. An empty result is
# not fatal here: it only matters when allow_current_ip is on, and the
# precondition in security.tf reports that in terms of the config.
CURRENT_IP = $(shell curl -sS --max-time 10 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')

TF_VARS = -var-file="$(ENV).tfvars" -var="current_ip=$(CURRENT_IP)"

# terraform's own "Enter a value:" prompt is the last thing standing between a
# typo and a deleted database, so it stays on by default. AUTO_APPROVE=1 turns
# it off for the whole run — including every stack `destroy-all` recurses into,
# since a variable set on the command line reaches sub-makes through MAKEFLAGS.
TF_APPROVE = $(if $(AUTO_APPROVE),-auto-approve)

# Every environment that has a tfvars file, so adding one is enough to have it
# torn down too. A hand-kept list here would go stale exactly once — on the env
# nobody remembered — and the first sign of that is an AWS bill for a stack no
# command can see any more. An env that was never applied costs one no-op
# destroy against an empty state, which is the cheaper failure by a distance.
# *.auto.tfvars is a local overlay on an env, not an env; keep it out.
ENVS ?= $(filter-out %.auto,$(patsubst %.tfvars,%,$(wildcard *.tfvars)))

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
        destroy-all destroy-bootstrap destroy-app destroy-bastion destroy-db \
        db-deps uv-check db-init db-check db-shell db-url db-secret db-env \
        db-query db-wait db-start db-stop db-tunnel \
        db-dump db-dump-remote db-restore-local db-dump-push db-dump-pull \
        app-login app-build app-push app-deploy app-status app-wait app-logs \
        app-url app-dns app-shell app-scale app-password app-hf-token app-mapbox-token

help:
	@grep -E '^[a-z-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# Order-only so a failure stops the run before anything touches AWS, and so the
# check runs once per invocation no matter how many of these are named.
bootstrap init-shared plan-shared apply-shared destroy-shared \
init plan apply destroy validate output destroy-all destroy-bootstrap \
destroy-app destroy-bastion destroy-db: | aws-check
db-init db-bootstrap db-ca db-check db-shell db-url db-secret db-env db-app-env \
db-query db-wait db-start db-stop db-tunnel \
db-dump db-dump-remote db-dump-push db-dump-pull: | aws-check
app-login app-build app-push app-deploy app-status app-wait app-logs \
app-url app-dns app-shell app-scale app-password app-hf-token app-mapbox-token: | aws-check

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
# without the shared outputs. `make destroy-all` walks them in that order.
destroy-shared: init-shared ## Destroy the shared VPC stack
	$(TF_SHARED) destroy $(TF_APPROVE)

init: ## terraform init for ENV
	$(TF) init -reconfigure $(TF_BACKEND)

plan: init ## Plan ENV
	$(TF) plan $(TF_VARS) -out=tfplan

apply: ## Apply ENV (run plan first)
	$(TF) apply tfplan && rm -f tfplan

destroy: init ## Destroy ENV
	@$(call preflight_destroy,$(ENV))
	$(TF) destroy $(TF_VARS) $(TF_APPROVE)

fmt: ## Rewrite all .tf files to canonical format
	$(TF) fmt -recursive .

validate: init ## Validate the per-env configuration
	$(TF) validate

output: ## Show ENV outputs
	$(TF) output

# ---------------------------------------------------------------------------
# Teardown
#
#   make destroy      ENV=dev   # one environment
#   make destroy-all            # every environment, then the shared stack
#   make destroy-bootstrap      # ...and the state backend that held all of it
#
# The order is the whole point. A per-env stack reads the shared one through
# data.terraform_remote_state, so a shared stack destroyed first leaves every
# env stack unplannable: `make destroy ENV=dev` then fails on the lookup rather
# than on anything it is trying to delete, and the only way forward is to apply
# the shared stack back. destroy-all walks them in the order that works.
#
# Nothing here happens by accident. Each target prints what it is about to
# remove and waits for its own name to be typed back; CONFIRM=<target> is the
# same answer given up front, which is what makes these usable from a script
# without making them usable by a stray Enter.
# ---------------------------------------------------------------------------

# Typing the target's own name, rather than y/n: a prompt answered by reflex is
# not a confirmation. Read from /dev/tty and not stdin, because make is often
# run with stdin redirected and a `read` that hits EOF returns an empty answer
# — rejected either way, but reported as if someone had declined.
define confirm
if [ "$(CONFIRM)" = "$(1)" ]; then \
  echo "(confirmed by CONFIRM=$(1))" >&2; \
elif [ -r /dev/tty ]; then \
  printf 'Type %s to continue: ' '$(1)' >&2; \
  read -r reply </dev/tty; \
  [ "$$reply" = "$(1)" ] || { echo "aborted — nothing was destroyed." >&2; exit 1; }; \
else \
  echo "refusing: no terminal to confirm at, and CONFIRM=$(1) was not passed." >&2; \
  exit 1; \
fi
endef

# The two things that stop a destroy, checked before terraform has spent ten
# minutes deleting the cheap half of the stack and then given up:
#
#   - deletion protection. It is an attribute on the live instance and the live
#     load balancer, and destroy deletes rather than modifies, so passing
#     -var=db_deletion_protection=false here changes nothing at all: AWS still
#     refuses, and by then the subnets, the secrets and the service are gone.
#     It has to come off in an apply first, which is what UNPROTECT=1 does.
#     Read from the tfvars rather than from AWS because the tfvars is what an
#     apply would put back — an instance unprotected by hand still has a config
#     that re-protects it on the next apply.
#   - a stopped instance. `make db-stop` leaves it in `stopped`, and RDS will
#     not delete from there; on prod, where a final snapshot is taken, it could
#     not take one anyway. Asked of AWS, since nothing in the config says it.
define preflight_destroy
prot=$$(grep -Ec '^[[:space:]]*(db|app)_deletion_protection[[:space:]]*=[[:space:]]*true' $(1).tfvars 2>/dev/null || true); \
if [ "$${prot:-0}" -gt 0 ]; then \
  if [ -n "$(UNPROTECT)" ]; then \
    echo "==> $(1): taking deletion protection off first" >&2; \
    $(TF) apply $(TF_VARS) -auto-approve \
      -var="db_deletion_protection=false" -var="app_deletion_protection=false" \
      -target=aws_db_instance.main -target=aws_lb.app || exit 1; \
  else \
    echo "$(1).tfvars leaves deletion protection on, and a destroy cannot take it" >&2; \
    echo "  off on the way past — AWS refuses the delete once the rest of the" >&2; \
    echo "  stack is already gone. Re-run as:" >&2; \
    echo "    make destroy ENV=$(1) UNPROTECT=1" >&2; \
    exit 1; \
  fi; \
fi; \
state=$$(aws rds describe-db-instances --region $(AWS_REGION) \
  --db-instance-identifier $(PROJECT)-$(1) \
  --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || true); \
if [ "$$state" = "stopped" ]; then \
  echo "$(PROJECT)-$(1) is stopped, and RDS will not delete it from there:" >&2; \
  echo "    make db-start db-wait ENV=$(1)" >&2; \
  exit 1; \
fi
endef

destroy-all: ## Destroy every environment, then the shared stack
	@echo "This destroys, in order:" >&2
	@for e in $(ENVS); do \
	  echo "  $$e — the RDS instance and everything in it, the ECS service, the" >&2; \
	  echo "        load balancer, the bastion, the SSM parameters, the secrets" >&2; \
	done
	@echo "  shared — the VPC and subnets, and the ECR repository with every" >&2
	@echo "        image in it" >&2
	@echo "" >&2
	@for e in $(ENVS); do \
	  grep -qE '^[[:space:]]*db_skip_final_snapshot[[:space:]]*=[[:space:]]*true' $$e.tfvars 2>/dev/null \
	    && echo "$$e takes no final snapshot — its data leaves no copy behind." >&2; \
	done; true
	@echo "Left standing on purpose: s3://$(BUCKET), the $(LOCK_TABLE) table," >&2
	@echo "and the GitHub deploy role — those are \`make destroy-bootstrap\`." >&2
	@$(call confirm,destroy-all)
	@for e in $(ENVS); do \
	  echo "" >&2; echo "==> destroy ENV=$$e" >&2; \
	  $(MAKE) --no-print-directory destroy ENV=$$e || exit 1; \
	done
	@echo "" >&2; echo "==> destroy-shared" >&2
	@$(MAKE) --no-print-directory destroy-shared
	@echo "" >&2
	@echo "every stack is gone. The state backend still stands:" >&2
	@echo "    make destroy-bootstrap" >&2

# Everything `make bootstrap` created, and the only stack whose state is local.
# That last part is the catch: bootstrap/terraform.tfstate is gitignored, so
# this works only from the machine that ran `make bootstrap`. Anywhere else it
# finds an empty state, destroys nothing, and still reports success — so the
# last line checks the bucket rather than trusting the exit code.
#
# Three things have to happen that `terraform destroy` will not do by itself:
#
#   - every other stack has to be empty first. Deleting this bucket deletes the
#     record of what exists; anything still standing afterwards can only be
#     found by hand, in the console, one service at a time.
#   - the bucket has to be emptied, version by version. It is versioned, so
#     `aws s3 rm --recursive` is not enough — the old versions and the delete
#     markers it leaves behind both keep DeleteBucket answering BucketNotEmpty.
#     One delete-object per version rather than a batched delete-objects, whose
#     --delete argument is either inline JSON or a file:// path, and msys
#     mangles both on the way to a native Windows aws.exe.
#   - prevent_destroy has to be got around. It takes a literal, not a variable,
#     so no flag can turn it off; dropping the bucket and its sub-resources out
#     of state and deleting it afterwards is the intended escape. The state
#     file is being destroyed in the same breath, so there is nothing to orphan.
destroy-bootstrap: ## Destroy the state bucket, lock table, and GitHub deploy role
	@echo "This deletes the Terraform state backend itself:" >&2
	@echo "  s3://$(BUCKET) — every version of every state file" >&2
	@echo "  the $(LOCK_TABLE) lock table" >&2
	@echo "  the hbu-github-deploy role — GitHub Actions deploys stop working" >&2
	@echo "" >&2
	@echo "There is no undo, and no state left afterwards to describe whatever" >&2
	@echo "survived it. Run \`make destroy-all\` first." >&2
	@echo "" >&2
	@echo "checking that nothing is left in the state files..." >&2
	@left=""; \
	for k in shared $(ENVS); do \
	  n=$$(aws s3 cp "s3://$(BUCKET)/$(PROJECT)/$$k/terraform.tfstate" - 2>/dev/null \
	       | grep -c '"mode": "managed"' || true); \
	  [ "$${n:-0}" -eq 0 ] || { echo "  $$k still holds $$n resources" >&2; left=1; }; \
	done; \
	[ -z "$$left" ] || { \
	  echo "refusing: destroying the backend now would strand them." >&2; \
	  echo "    make destroy-all" >&2; exit 1; }
	@echo "  clean." >&2
	@$(call confirm,destroy-bootstrap)
	@echo "==> emptying s3://$(BUCKET)" >&2
	@aws s3api list-object-versions --bucket "$(BUCKET)" \
	   --query '[Versions, DeleteMarkers][][].[Key, VersionId]' --output text 2>/dev/null \
	 | while read -r key vid; do \
	     [ -n "$$key" ] || continue; \
	     aws s3api delete-object --bucket "$(BUCKET)" --key "$$key" --version-id "$$vid" >/dev/null; \
	   done
	@echo "==> dropping the bucket out of state (prevent_destroy takes no flag)" >&2
	@$(TF_BOOT) init -input=false >/dev/null
	@for r in aws_s3_bucket.tf_state aws_s3_bucket_versioning.tf_state \
	          aws_s3_bucket_server_side_encryption_configuration.tf_state \
	          aws_s3_bucket_public_access_block.tf_state; do \
	  $(TF_BOOT) state rm "$$r" >/dev/null 2>&1 || true; \
	done
	$(TF_BOOT) destroy $(TF_APPROVE)
	@aws s3api delete-bucket --bucket "$(BUCKET)" --region $(AWS_REGION) 2>/dev/null || true
	@if aws s3api head-bucket --bucket "$(BUCKET)" 2>/dev/null; then \
	  echo "s3://$(BUCKET) is still there — delete it by hand." >&2; exit 1; \
	else echo "s3://$(BUCKET) is gone. Nothing of this project is left in AWS." >&2; fi

# ---------------------------------------------------------------------------
# Partial teardown — one part of ENV at a time, in the order the bill suggests
#
#   make destroy-app     ENV=dev   # the ALB + Fargate service (~$39/mo idle)
#   make destroy-bastion ENV=dev   # the jump host (~$7/mo)
#   make destroy-db      ENV=dev   # the instance itself — dump it out first
#
# destroy-app and destroy-bastion are the enable_* toggles applied off: the
# same thing as editing the tfvars, minus the edit. That is also their catch —
# the tfvars still says true, so the next plain `make plan apply` puts the part
# back. Edit $(ENV).tfvars to make either permanent.
#
# destroy-db is a targeted destroy instead, because the instance has no
# toggle. Terraform takes its dependents with it — the /hbu-$(ENV)/db/* SSM
# contract, the db_access policy, the stop/start schedules — and warns that
# -target is for exceptional use; removing one resource from a stack you are
# keeping is that exception. What it leaves behind (parameter group, log
# group, security group, the empty app-role secret) costs pennies and is
# re-adopted by the next `make plan apply`, which recreates an *empty*
# instance: the data comes back with `make db-restore-local` in reverse, or
# not at all — see "Moving the database off AWS" in the README.
# ---------------------------------------------------------------------------

destroy-app: init ## Remove the ALB + ECS service from ENV (DB and bastion stay)
	@echo "This removes from $(ENV): the load balancer — and its DNS name, so any" >&2
	@echo "CNAME pointing at it must be repointed after a re-create — the ECS" >&2
	@echo "cluster and service, and the app's three secrets (password, HF token," >&2
	@echo "Mapbox token), which block re-creation under the same name for their" >&2
	@echo "7-day recovery window. $(ENV).tfvars still sets enable_app = true, so" >&2
	@echo "the next plain \`make plan apply\` puts it all back; edit the tfvars to" >&2
	@echo "make this permanent." >&2
	@$(call confirm,destroy-app)
	$(TF) apply $(TF_VARS) -var="enable_app=false" $(TF_APPROVE)

destroy-bastion: init ## Remove the SSM bastion from ENV — severs db-* to a private DB
	@echo "This removes the $(ENV) bastion. With db_subnet_tier = private that" >&2
	@echo "was the only path from a laptop: db-tunnel, db-dump, db-shell and the" >&2
	@echo "rest keep working only until the current SSM session ends. Same catch" >&2
	@echo "as destroy-app: $(ENV).tfvars still says enable_bastion = true." >&2
	@$(call confirm,destroy-bastion)
	$(TF) apply $(TF_VARS) -var="enable_bastion=false" $(TF_APPROVE)

destroy-db: init ## Destroy ONLY the RDS instance (VPC, app, bastion stay)
	@$(call preflight_destroy,$(ENV))
	@echo "This deletes the $(PROJECT)-$(ENV) instance and every row in it." >&2
	@grep -qE '^[[:space:]]*db_skip_final_snapshot[[:space:]]*=[[:space:]]*true' $(ENV).tfvars 2>/dev/null \
	  && echo "$(ENV) takes no final snapshot — without a dump, the data leaves no copy." >&2 \
	  || true
	@echo "Its SSM contract, IAM policy and stop/start schedules go with it." >&2
	@$(call confirm,destroy-db)
	$(TF) destroy $(TF_VARS) -target=aws_db_instance.main $(TF_APPROVE)

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

db-init: ## Apply sql/*.sql — roles, extensions, the rag working set, the silver/gold tables
	$(DB) init

# sql/000_roles.sql is applied by db-init too, since it sorts first. What only
# this target does is the credential no .sql file carries: generate the role's
# password, set it, and write it to the secret Terraform created for it.
db-bootstrap: ## Create the urban_rag role + grants, storing its password in Secrets Manager
	$(DB) bootstrap --store-password

db-ca: ## Download the RDS root certificate that sslmode=verify-full needs
	$(DB) ca

db-check: ## Report extensions, tables, partitions, and what is loaded
	$(DB) check

db-shell: ## Interactive SQL (psql when installed, built-in REPL otherwise)
	$(DB) shell

db-url: ## Print the connection URL
	$(DB) url

db-secret: ## Print the RDS master secret, plus password_urlencoded and database_url
	@$(DB) secret

db-env: ## Master-user exports - use as: eval "$$(make -s db-env)"
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
# 127.0.0.1:$(LOCAL_PORT) — not `localhost`, which Windows answers with ::1
# first and where libpq then burns its whole connect_timeout before falling
# back — for as long as this runs.
#
# Supervised: it probes the session every 2 minutes, which both keeps SSM from
# idling it out during a long materialisation and detects the case where it died
# anyway, and reconnects with backoff when it has. See "The tunnel supervises
# itself" in the README for the tunables (TUNNEL_SUPERVISE=0 for a plain
# one-shot session) and for why a public endpoint is not the simpler answer.
db-tunnel: ## Supervised port-forward through the SSM bastion to 127.0.0.1:$(LOCAL_PORT)
	./scripts/tunnel.sh $(ENV) $(LOCAL_PORT) $(AWS_REGION)

# ---------------------------------------------------------------------------
# Getting the data out — see "Moving the database off AWS" in the README
#
#   make db-dump-remote ENV=dev     # the fast path: bastion -> S3 -> backups/
#   make db-restore-local           # the dump into hbu_rag_map's container
#   make db-dump-pull               # (another machine) newest dump from S3
#
#   make db-dump ENV=dev TUNNEL=1   # the slow path, through an open db-tunnel
#   make db-dump-push               # ...and that artifact to S3
#
# The dump is the artifact that travels. It is a `pg_dump --format=custom` of
# the whole database — rag, silver, gold and dagster, schema and data — which
# is both the migration to the local container and the off-machine copy, where
# a tar of the pgdata volume would be neither: twice the size, pinned to one
# postgres build, and restorable only into docker.
#
# On the laptop side pg_dump and pg_restore run inside the local database
# image rather than on the host, so their version always matches the server
# they talk to and nothing has to be installed. The image is hbu_rag_map's
# local stand-in (postgis + pgvector, built by `make db-up` over there), which
# is also where db-restore-local puts the data.
# ---------------------------------------------------------------------------

BACKUP_DIR    ?= backups
# The dataplatform's own bucket — it survives every stack here on purpose, so
# the parquet, the tiles and these dumps all outlive the RDS.
BACKUP_BUCKET ?= urban-rag-dataplatform
BACKUP_PREFIX ?= backups/db
# Parallel restore workers. 4 is sensible for a laptop; 1 to stay out of the way.
RESTORE_JOBS  ?= 4

PG_CLIENT_IMAGE    ?= hbu-rag-map/postgis-pgvector:16
LOCAL_DB_CONTAINER ?= hbu-rag-map-db

# Git Bash rewrites leading-slash arguments into C:\... paths on the way to a
# native docker.exe, which turns `/tmp/restore.dump` inside the container into
# a host path that does not exist there — and the MSYS_NO_PATHCONV env guard
# does not reliably survive a make recipe's shell (verified: pg_dump was handed
# C:/Users/.../Git/backups/... inside the container with the guard in place).
# So every in-container absolute path below is written with a double slash,
# which the MSYS runtime leaves alone and Linux reads as a single one. The env
# guard stays as a belt for the arguments that are not paths at all.
DOCKER_NOCONV = MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

# The newest dump under $(BACKUP_DIR), unless DUMP= names one. Resolved in the
# recipes (`=` would still be too early), shared so push and restore agree on
# what "the latest" means.
define resolve_dump
dump="$(DUMP)"; [ -n "$$dump" ] || dump=$$(ls -t $(BACKUP_DIR)/*.dump 2>/dev/null | head -1); \
[ -n "$$dump" ] && [ -f "$$dump" ] || { \
  echo "no dump under $(BACKUP_DIR)/ — run \`make db-dump ENV=$(ENV) TUNNEL=1\` first," >&2; \
  echo "  \`make db-dump-pull\` to fetch one from S3, or pass DUMP=<path>." >&2; exit 1; }
endef

# The whole database, through the tunnel, into one compressed archive. The
# credentials come from the same place every other db-* target gets them, so
# this takes no host or password; the master user reads everything because
# 000_roles.sql grants it the urban_rag role WITH INHERIT. Written to a .part
# first so a dump killed halfway — the tunnel dropping, the 22:30 scheduled
# stop — never leaves something that looks like a finished artifact.
db-dump: ## pg_dump of ENV into backups/ (through an open db-tunnel: TUNNEL=1)
	@mkdir -p $(BACKUP_DIR)
	@eval "$$($(DB) env)"; \
	host="$$PGHOST"; [ "$$host" = "127.0.0.1" ] && host=host.docker.internal; \
	$(DOCKER_NOCONV) docker run --rm --add-host=host.docker.internal:host-gateway \
	  -e PGPASSWORD="$$PGPASSWORD" $(PG_CLIENT_IMAGE) \
	  pg_isready -h "$$host" -p "$$PGPORT" -t 10 >/dev/null || { \
	    echo "cannot reach $$host:$$PGPORT from a container." >&2; \
	    echo "  with TUNNEL=1: is \`make db-tunnel ENV=$(ENV)\` still running — and the" >&2; \
	    echo "  instance started? (the dev schedule stops it 22:30-07:00.)" >&2; \
	    echo "  without TUNNEL=1 this dials the endpoint directly, which only works" >&2; \
	    echo "  from inside the VPC: open a tunnel and re-run with TUNNEL=1." >&2; \
	    exit 1; }; \
	ts=$$(date +%Y%m%d-%H%M%S); out="hbu-$(ENV)-$$ts.dump"; \
	bdir=$$(cd $(BACKUP_DIR) && { pwd -W 2>/dev/null || pwd; }); \
	echo "==> pg_dump $(ENV) -> $(BACKUP_DIR)/$$out" >&2; \
	$(DOCKER_NOCONV) docker run --rm --add-host=host.docker.internal:host-gateway \
	  -e PGHOST="$$host" -e PGPORT="$$PGPORT" -e PGUSER="$$PGUSER" \
	  -e PGPASSWORD="$$PGPASSWORD" -e PGDATABASE="$$PGDATABASE" -e PGSSLMODE=require \
	  -v "$$bdir:/backups" $(PG_CLIENT_IMAGE) \
	  pg_dump --format=custom --compress=6 --no-password \
	    --file="//backups/$$out.part" \
	&& mv "$(BACKUP_DIR)/$$out.part" "$(BACKUP_DIR)/$$out" \
	&& ls -lh "$(BACKUP_DIR)/$$out"

# Into hbu_rag_map's local container, REPLACING whatever urban_rag database it
# holds. The container is left to that repo to run (`make db-up` there);
# `--no-owner --no-acl` because the restoring role owns the whole local
# database and the RDS-side roles (hbu_admin, urban_rag_ro) do not exist here.
#
# pg_restore runs in a throwaway client container that mounts $(BACKUP_DIR)
# and dials the published port — the same shape as db-dump — rather than
# `docker cp` + `docker exec`: cp needs a bare container:/path argument, which
# is exactly what the MSYS runtime mangles (and the // spelling that saves a
# mounted path confuses docker cp instead). The drop/create steps are fatal on
# failure; pg_restore's own exit code is reported but not, because the count
# table printed at the end is the real verdict and a 45-minute restore should
# not read as wasted over one benign warning.
db-restore-local: ## Restore the newest dump (or DUMP=) into the local container
	@$(call resolve_dump); \
	docker exec $(LOCAL_DB_CONTAINER) pg_isready -U urban_rag -d postgres >/dev/null 2>&1 || { \
	  echo "the local container is not running. In $(APP_DIR):  make db-up" >&2; exit 1; }; \
	docker port $(LOCAL_DB_CONTAINER) 5432 >/dev/null 2>&1 || { \
	  echo "$(LOCAL_DB_CONTAINER) is running but publishes no port, so pg_restore could not reach it." >&2; \
	  echo "  In $(APP_DIR):  make db-up   (recreates it; the data volume is kept)" >&2; exit 1; }; \
	echo "==> replacing database urban_rag in $(LOCAL_DB_CONTAINER) with $$dump" >&2; \
	docker exec $(LOCAL_DB_CONTAINER) dropdb -U urban_rag --force --if-exists urban_rag || exit 1; \
	docker exec $(LOCAL_DB_CONTAINER) createdb -U urban_rag urban_rag || exit 1; \
	bdir=$$(cd "$$(dirname "$$dump")" && { pwd -W 2>/dev/null || pwd; }); \
	f=$$(basename "$$dump"); \
	$(DOCKER_NOCONV) docker run --rm --add-host=host.docker.internal:host-gateway \
	  -v "$$bdir:/backups" -e PGPASSWORD=urban_rag $(PG_CLIENT_IMAGE) \
	  pg_restore -h host.docker.internal -p "$${HBU_LOCAL_PG_PORT:-5432}" \
	    -U urban_rag -d urban_rag --no-owner --no-acl \
	    --jobs=$(RESTORE_JOBS) "//backups/$$f" \
	  || echo "pg_restore reported errors above — check the counts below before trusting or redoing" >&2; \
	echo "==> ANALYZE" >&2; \
	docker exec $(LOCAL_DB_CONTAINER) psql -q -U urban_rag -d urban_rag -c "ANALYZE;"; \
	docker exec $(LOCAL_DB_CONTAINER) psql -U urban_rag -d urban_rag -c \
	  "select schemaname, count(*) as tables, pg_size_pretty(sum(pg_total_relation_size(schemaname||'.'||quote_ident(tablename)))::bigint) as size from pg_tables where schemaname in ('rag','silver','gold','dagster') group by 1 order by 1;"; \
	echo "point the apps at it:" >&2; \
	echo "  hbu_rag_map:      make run   (DB_TARGET=local is the default)" >&2; \
	echo "  anything else:    DATABASE_URL=postgresql://urban_rag:urban_rag@127.0.0.1:$${HBU_LOCAL_PG_PORT:-5432}/urban_rag?sslmode=disable" >&2

# The fast path, and the one to prefer for a full copy: the tunnel the target
# above rides tops out around 300 KB/s per SSM session (parallel connections
# share the one websocket — measured 2026-10-01), which on this database is
# half a day and a death at the 22:30 scheduled stop. This one runs pg_dump on
# the bastion instead — VPC speed next to the instance, EC2 speed up to S3 —
# and needs no tunnel at all; it ends by pulling the artifact down here.
db-dump-remote: ## pg_dump on the bastion straight to S3, then pulled here — the fast path
	PYTHONUNBUFFERED=1 $(DB) dump-remote --bucket "$(BACKUP_BUCKET)" --prefix "$(BACKUP_PREFIX)"
	@$(MAKE) --no-print-directory db-dump-pull

db-dump-push: ## Upload the newest dump (or DUMP=) to the dataplatform bucket on S3
	@$(call resolve_dump); \
	echo "==> s3://$(BACKUP_BUCKET)/$(BACKUP_PREFIX)/$$(basename $$dump)" >&2; \
	aws s3 cp "$$dump" "s3://$(BACKUP_BUCKET)/$(BACKUP_PREFIX)/$$(basename $$dump)"; \
	echo "on the next machine:  make db-dump-pull db-restore-local" >&2

db-dump-pull: ## Download the newest dump from S3 into backups/
	@mkdir -p $(BACKUP_DIR); \
	key=$$(aws s3api list-objects-v2 --bucket "$(BACKUP_BUCKET)" --prefix "$(BACKUP_PREFIX)/" \
	  --query 'sort_by(Contents,&LastModified)[-1].Key' --output text 2>/dev/null); \
	[ -n "$$key" ] && [ "$$key" != "None" ] || { \
	  echo "nothing under s3://$(BACKUP_BUCKET)/$(BACKUP_PREFIX)/ — \`make db-dump-push\` from the machine that has one" >&2; exit 1; }; \
	aws s3 cp "s3://$(BACKUP_BUCKET)/$$key" "$(BACKUP_DIR)/" && ls -lh "$(BACKUP_DIR)/$$(basename $$key)"

# How far back `make app-logs` starts. Overridable: SINCE=1h.
SINCE ?= 10m

# ---------------------------------------------------------------------------
# The web application
#
# Build here, run on Fargate. Every target below resolves the registry, the
# cluster, and the service from Terraform outputs at call time, so none of
# them take an account number, a repository URL, or a task ARN — and none of
# them break when the service is replaced.
#
#   make apply-shared             # once: creates the ECR repository
#   make app-push     ENV=dev     # build the image and push it
#   make app-password ENV=dev     # the shared password people log in with
#   make app-hf-token ENV=dev     # the Inference API token
#   make app-mapbox-token ENV=dev # the Mapbox basemap token (optional; OSM without it)
#   make plan apply   ENV=dev     # with enable_app = true in dev.tfvars
#   make app-url      ENV=dev     # where it ended up
#   make app-dns      ENV=dev     # the record to point a domain at it
#
# Afterwards a code change is two commands: app-push, then app-deploy.
# ---------------------------------------------------------------------------

# Where the application source lives, relative to this file. Sibling checkout
# by default; override if it sits somewhere else.
APP_DIR ?= ../hbu_rag_map

# The tag pushed and deployed. `latest` is what dev.tfvars pins the service to,
# so moving it and forcing a deployment is the whole update path. Override with
# a git sha for anything that has to be reproducible:
#   make app-push ENV=prod APP_TAG=$(git -C ../hbu_rag_map rev-parse --short HEAD)
APP_TAG ?= latest

# X86_64 in the task definition means linux/amd64 here. They have to agree:
# Fargate refuses a task whose image architecture does not match its
# runtime_platform, and the error names neither side.
APP_PLATFORM ?= linux/amd64

# Read from the *shared* stack, not the per-env one — the repository is shared.
# Resolved lazily (`=`, not `:=`) so the shell only runs for targets that use
# it, and so it does not fail this file's parse when terraform is not inited.
#
# $(AWS_SHELL_ENV) is not optional here, for the reason given where it is
# defined: terraform reads the state straight out of S3, so without the profile
# it authenticates as the default account and S3 answers HeadObject with 403.
# The 2>/dev/null below then ate that, and every app-* target reported it as an
# un-applied shared stack — which is why this looked like missing state for as
# long as it did.
# Memoized on first use. The state lives in S3, so each lookup is a ~5s round
# trip, and one `make app-push` references this five times over — the guard and
# the image tag in each of app-login and app-build, then the push itself. The
# $(eval)s expand to nothing, so this still yields just the URL. A failed
# lookup caches as empty too, which is what the guard below wants: it reports
# the failure once instead of re-running terraform at every reference.
ECR_URL      = $(if $(_ECR_DONE),,$(eval _ECR_DONE := 1)$(eval _ECR_URL := $(_ECR_URL_SH)))$(_ECR_URL)
_ECR_URL_SH  = $(shell $(AWS_SHELL_ENV) $(TF_SHARED) output -raw ecr_repository_url 2>/dev/null)
ECR_HOST     = $(firstword $(subst /, ,$(ECR_URL)))

# Re-run the lookup with stderr attached so the failure explains itself. Only
# ever reached when ECR_URL came back empty, so the second terraform call costs
# nothing in the normal path.
define require_ecr_url
[ -n "$(ECR_URL)" ] || { \
  echo "no ecr_repository_url output from the shared stack. terraform says:" >&2; \
  $(AWS_SHELL_ENV) $(TF_SHARED) output -raw ecr_repository_url >/dev/null; \
  echo "(if the state itself is missing, run \`make apply-shared\`)" >&2; \
  exit 1; }
endef

TF_OUT = $(TF) output -raw

app-login: ## Log docker in to the shared ECR registry
	@$(require_ecr_url)
	@aws ecr get-login-password --region $(AWS_REGION) \
	  | docker login --username AWS --password-stdin "$(ECR_HOST)"

app-build: ## Build the runtime image from $(APP_DIR)
	@$(require_ecr_url)
	@docker build --target runtime --platform $(APP_PLATFORM) \
	  --build-arg BUILD_VERSION=$(APP_TAG) \
	  -t "$(ECR_URL):$(APP_TAG)" $(APP_DIR)

app-push: app-login app-build ## Build and push the image to ECR
	@docker push "$(ECR_URL):$(APP_TAG)"

# Forces a new deployment of the *same* task definition, which is what picks up
# a moved `latest`. A changed task definition — new CPU, new secret, new env —
# is a terraform apply, not this.
app-deploy: ## Roll the service onto the image currently tagged $(APP_TAG)
	@aws ecs update-service --region $(AWS_REGION) \
	  --cluster "$$($(TF_OUT) app_cluster)" \
	  --service "$$($(TF_OUT) app_service)" \
	  --force-new-deployment --output text --query 'service.serviceName'
	@echo "rolling — follow it with: make app-status ENV=$(ENV)"

app-status: ## Running/desired counts and the last few deployment events
	@c="$$($(TF_OUT) app_cluster)"; s="$$($(TF_OUT) app_service)"; \
	aws ecs describe-services --region $(AWS_REGION) --cluster "$$c" --services "$$s" \
	  --query 'services[0].{desired:desiredCount,running:runningCount,pending:pendingCount,status:status}' \
	  --output table; \
	aws ecs describe-services --region $(AWS_REGION) --cluster "$$c" --services "$$s" \
	  --query 'services[0].events[:5].message' --output text | tr '\t' '\n'

app-wait: ## Block until the service is stable (what a deploy succeeding looks like)
	@aws ecs wait services-stable --region $(AWS_REGION) \
	  --cluster "$$($(TF_OUT) app_cluster)" \
	  --services "$$($(TF_OUT) app_service)" && echo "stable"

app-logs: ## Tail the container's stdout
	@aws logs tail "$$($(TF_OUT) app_log_group)" --region $(AWS_REGION) \
	  --follow --since $(SINCE)

app-url: ## Print where the front end is served
	@$(TF_OUT) app_url; echo

app-dns: ## Print the record to point a domain at the load balancer
	@$(TF) output -raw app_dns_record; echo

# ECS Exec, over the same SSM channel the bastion uses. Needs
# app_enable_execute_command = true and the session-manager-plugin installed.
app-shell: ## Open a shell inside a running task
	@c="$$($(TF_OUT) app_cluster)"; s="$$($(TF_OUT) app_service)"; \
	t=$$(aws ecs list-tasks --region $(AWS_REGION) --cluster "$$c" --service-name "$$s" \
	     --desired-status RUNNING --query 'taskArns[0]' --output text); \
	[ "$$t" != "None" ] || { echo "no running task in $$s" >&2; exit 1; }; \
	aws ecs execute-command --region $(AWS_REGION) --cluster "$$c" --task "$$t" \
	  --container app --interactive --command /bin/bash

app-scale: ## Set the task count: make app-scale ENV=dev COUNT=0
	@[ -n "$(COUNT)" ] || { echo "usage: make app-scale ENV=$(ENV) COUNT=<n>" >&2; exit 1; }
	@aws ecs update-service --region $(AWS_REGION) \
	  --cluster "$$($(TF_OUT) app_cluster)" \
	  --service "$$($(TF_OUT) app_service)" \
	  --desired-count $(COUNT) --output text --query 'service.desiredCount'

# ---------------------------------------------------------------------------
# Secrets
#
# Terraform creates both with a placeholder and then ignores the value, so
# these write straight to Secrets Manager and never pass through a plan or a
# state file. A task reads its secrets once, at start, so both targets end by
# telling you the change is not live until the service rolls.
# ---------------------------------------------------------------------------

# Read with `read -s` rather than taken as a variable: a make argument is in
# the process list and in the shell history, which for a password is the
# difference between a secret and a published one.
app-password: ## Set the shared access password (prompts; never echoed)
	@arn="$$($(TF_OUT) app_password_secret_arn)"; \
	printf 'New shared access password: ' >&2; stty -echo 2>/dev/null; \
	read -r p; stty echo 2>/dev/null; printf '\n' >&2; \
	printf 'Again: ' >&2; stty -echo 2>/dev/null; \
	read -r q; stty echo 2>/dev/null; printf '\n' >&2; \
	[ -n "$$p" ] || { echo "empty password — the gate would be off entirely" >&2; exit 1; }; \
	[ "$$p" = "$$q" ] || { echo "they do not match" >&2; exit 1; }; \
	aws secretsmanager put-secret-value --region $(AWS_REGION) \
	  --secret-id "$$arn" --secret-string "$$p" \
	  --query 'VersionId' --output text >/dev/null; \
	echo "stored. Running tasks keep the old one until: make app-deploy ENV=$(ENV)"

app-hf-token: ## Set the HuggingFace Inference API token (prompts; never echoed)
	@arn="$$($(TF_OUT) app_hf_token_secret_arn)"; \
	printf 'HuggingFace API token (hf_...): ' >&2; stty -echo 2>/dev/null; \
	read -r t; stty echo 2>/dev/null; printf '\n' >&2; \
	[ -n "$$t" ] || { echo "empty token" >&2; exit 1; }; \
	aws secretsmanager put-secret-value --region $(AWS_REGION) \
	  --secret-id "$$arn" --secret-string "$$t" \
	  --query 'VersionId' --output text >/dev/null; \
	echo "stored. Running tasks keep the old one until: make app-deploy ENV=$(ENV)"

# A Mapbox *public* token (pk....). Unlike the two above it is not really a
# secret — it ships to the browser inside every tile URL — but it is kept out
# of git and out of state the same way, and restricting it to the app's
# domain(s) in the Mapbox console is what actually guards it. Left unset the
# map falls back to OpenStreetMap, so this target is optional.
app-mapbox-token: ## Set the Mapbox basemap token (prompts; optional — OSM without it)
	@arn="$$($(TF_OUT) app_mapbox_token_secret_arn)"; \
	printf 'Mapbox public token (pk....): ' >&2; stty -echo 2>/dev/null; \
	read -r t; stty echo 2>/dev/null; printf '\n' >&2; \
	[ -n "$$t" ] || { echo "empty token" >&2; exit 1; }; \
	aws secretsmanager put-secret-value --region $(AWS_REGION) \
	  --secret-id "$$arn" --secret-string "$$t" \
	  --query 'VersionId' --output text >/dev/null; \
	echo "stored. Running tasks keep the old one until: make app-deploy ENV=$(ENV)"
