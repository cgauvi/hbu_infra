# ---------------------------------------------------------------------------
# The map's tiles — read off the dataplatform's bucket
#
# hbu_rag_map draws its nine layers from PMTiles archives: one file per layer
# per (scrape_date, borough) partition, rendered by the dataplatform's
# `map_tiles` asset and written into that pipeline's own S3 tree under
# `<env>/gold/map_tiles/`. The browser fetches any one tile with a byte-range
# request against the archive, so nothing in this stack is in the path of a
# pan — not the task, not the database.
#
# Two things have to be true of the bucket for that to work, and this file is
# both of them:
#
#   * the task role may read the archives, so the app can presign a URL per
#     archive with its own credentials. The bucket stays private: a presigned
#     URL comes from a page, and a page is what the password gate hands out,
#     which keeps the tiles exactly as reachable as the app and no more;
#   * the bucket answers cross-origin range requests, because the page is
#     served from the load balancer's origin and the archive from S3's. A
#     `Range` header is not on the browser's safelist, so every read is
#     preflighted — the rule below is what lets it through, and it also has
#     to *expose* the headers the PMTiles reader checks.
#
# The bucket itself is not created here. It belongs to the dataplatform — it
# is the pipeline's whole output tree, bronze through gold — and it predates
# this stack. `app_tiles_bucket` names it; leave it empty and none of this is
# created, and the app draws its GeoJSON fallback and says so in the sidebar.
#
# Managing the CORS configuration of a bucket created elsewhere is the one
# thing here that reaches outside this stack's own resources, and it is done
# deliberately: the rule exists only for this app, so this is the stack that
# should own it. A second consumer with its own CORS needs would move the rule
# into the dataplatform's own Terraform, if it ever grows one.
# ---------------------------------------------------------------------------

locals {
  tiles_enabled = var.enable_app && var.app_tiles_bucket != ""
  tiles_prefix  = var.app_tiles_prefix != "" ? var.app_tiles_prefix : "${var.environment}/gold/map_tiles"
  tiles_url     = local.tiles_enabled ? "s3://${var.app_tiles_bucket}/${local.tiles_prefix}" : ""
}

# Fails the plan on a bucket that does not exist, which is a better place to
# find that out than a sidebar note after a deploy.
data "aws_s3_bucket" "tiles" {
  count = local.tiles_enabled ? 1 : 0

  bucket = var.app_tiles_bucket
}

data "aws_iam_policy_document" "app_task_tiles" {
  count = local.tiles_enabled ? 1 : 0

  # The archives and the manifest beside them, under the one prefix. Nothing
  # else in the tree: bronze holds what the publishers returned and gold the
  # tables the archives were rendered from, and the map reads neither.
  statement {
    sid       = "ReadTileArchives"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${data.aws_s3_bucket.tiles[0].arn}/${local.tiles_prefix}/*"]
  }

  # ListBucket, scoped to the prefix, for one reason: without it S3 answers a
  # GetObject on a key that is not there with 403 rather than 404, and the app
  # cannot tell "no tiles built for this snapshot" from "no permission".
  statement {
    sid       = "ListTileArchives"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [data.aws_s3_bucket.tiles[0].arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${local.tiles_prefix}/*"]
    }
  }
}

resource "aws_iam_role_policy" "app_task_tiles" {
  count = local.tiles_enabled ? 1 : 0

  name   = "${local.prefix}-app-task-tiles"
  role   = aws_iam_role.app_task[0].id
  policy = data.aws_iam_policy_document.app_task_tiles[0].json
}

# The CORS rule the PMTiles reader needs. `*` for the origin is the default
# and is safe here because the objects are private: a browser can only read
# what it holds a presigned URL for, and the rule decides nothing about who
# gets one. Narrow it to the app's own origin once a domain is in front of the
# load balancer, if only so a stray URL cannot be embedded elsewhere for the
# hour it is valid.
resource "aws_s3_bucket_cors_configuration" "tiles" {
  count = local.tiles_enabled ? 1 : 0

  bucket = data.aws_s3_bucket.tiles[0].id

  cors_rule {
    allowed_methods = ["GET", "HEAD"]
    allowed_origins = var.app_tiles_cors_origins
    # `Range` above all; `If-Match` is what the reader sends once it holds an
    # ETag, to notice an archive rewritten underneath it.
    allowed_headers = ["*"]
    # What a cross-origin page may *read* off the response. The reader
    # refuses a range response it cannot see the Content-Range of, and uses
    # the ETag to keep its directory cache honest across a re-materialisation.
    expose_headers  = ["ETag", "Content-Range", "Content-Length", "Accept-Ranges"]
    max_age_seconds = 3600
  }
}
