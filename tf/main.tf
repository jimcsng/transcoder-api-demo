provider "google" {
  project = var.project_id
  region  = var.region
}

# ------------------------------------------------------------------------------
# Project API Enablement
# ------------------------------------------------------------------------------

resource "google_project_service" "enable_transcoder" {
  project = var.project_id
  service = "transcoder.googleapis.com"

  timeouts {
    create = "30m"
    update = "40m"
  }

  disable_dependent_services = true
}

resource "google_project_service" "enable_gcf" {
  project = var.project_id
  service = "cloudfunctions.googleapis.com"

  timeouts {
    create = "30m"
    update = "40m"
  }

  disable_dependent_services = true
}

resource "google_project_service" "enable_cloudbuild" {
  project = var.project_id
  service = "cloudbuild.googleapis.com"

  timeouts {
    create = "30m"
    update = "40m"
  }

  disable_dependent_services = true
}

resource "google_project_service" "enable_compute" {
  project = var.project_id
  service = "compute.googleapis.com"

  timeouts {
    create = "30m"
    update = "40m"
  }

  disable_dependent_services = true
}

resource "time_sleep" "wait_10_seconds" {
  depends_on = [
      google_project_service.enable_gcf,
      google_project_service.enable_transcoder,
      google_project_service.enable_cloudbuild,
      google_project_service.enable_compute
  ]

  create_duration = "10s"
}

# ------------------------------------------------------------------------------
# GCS Buckets for input and output videos
# ------------------------------------------------------------------------------

resource "random_id" "project" {
    byte_length = 4
}


resource "google_storage_bucket" "transcoder_input_bucket" {
  name          = "transcoder-input-bucket-${random_id.project.hex}"
  location      = "ASIA-EAST2"
  force_destroy = true
  uniform_bucket_level_access = true
}

resource "google_storage_bucket" "transcoder_output_bucket" {
  name          = "transcoder-output-bucket-${random_id.project.hex}"
  location      = "ASIA-EAST2"
  force_destroy = true
  uniform_bucket_level_access = true
}

# ------------------------------------------------------------------------------
# IAM Related Resources
# ------------------------------------------------------------------------------

resource "google_service_account" "gcf_sa" {
    account_id   = "transcoder-gcf-sa"
    display_name = "Service Account for the transcoder job creation gcf"
}

resource "null_resource" "role_bindings" {
    provisioner "local-exec" {
      command = <<EOF
        gcloud projects add-iam-policy-binding  ${var.project_id} \
            --member serviceAccount:${var.project_number}@cloudbuild.gserviceaccount.com \
            --role  roles/storage.objectAdmin
        gcloud projects add-iam-policy-binding ${var.project_id} \
            --member serviceAccount:${google_service_account.gcf_sa.email} \
            --role roles/transcoder.admin
        gcloud projects add-iam-policy-binding ${var.project_id} \
            --member serviceAccount:${google_service_account.gcf_sa.email} \
            --role roles/storage.objectAdmin
      EOF
    }

    # Since customer node group is created, can only use depends_on to ensure
    # that the GKE cluster is in a ready state
    depends_on = [time_sleep.wait_10_seconds]
}

# ------------------------------------------------------------------------------
# GCF
# ------------------------------------------------------------------------------

resource "google_storage_bucket" "gcf_src_code_bucket" {
  name          = "transcoder-gcf-src-code-bucket-${random_id.project.hex}"
  location      = "ASIA-EAST2"
  force_destroy = true
  uniform_bucket_level_access = true
}

data "archive_file" "source" {
    type        = "zip"
    source_dir  = "../gcf_src"
    output_path = "/tmp/function.zip"
}

resource "google_storage_bucket_object" "zip" {
    source       = data.archive_file.source.output_path
    content_type = "application/zip"

    # Append to the MD5 checksum of the files's content
    # to force the zip to be updated as soon as a change occurs
    name         = "src-${data.archive_file.source.output_md5}.zip"
    bucket       = google_storage_bucket.gcf_src_code_bucket.name

    # Dependencies are automatically inferred so these lines can be deleted
    depends_on   = [
        google_storage_bucket.gcf_src_code_bucket,  # declared in `storage.tf`
        data.archive_file.source
    ]
}

resource "google_cloudfunctions_function" "function" {
    name                  = "create-transcoder-job-fn"
    runtime               = "nodejs14"  # of course changeable

    # Get the source code of the cloud function as a Zip compression
    source_archive_bucket = google_storage_bucket.gcf_src_code_bucket.name
    source_archive_object = google_storage_bucket_object.zip.name

    # Must match the function name in the cloud function `main.py` source code
    entry_point           = "createTranscodeJob"
    
    # 
    event_trigger {
        event_type = "google.storage.object.finalize"
        resource   = google_storage_bucket.transcoder_input_bucket.name
    }

    environment_variables = {
        OUTPUT_BUCKET = google_storage_bucket.transcoder_output_bucket.name
        TRANSCODER_LOC = "asia-east1"
        PROJ_ID = var.project_id
    }

    service_account_email = google_service_account.gcf_sa.email
    ingress_settings = "ALLOW_INTERNAL_AND_GCLB"

    depends_on = [
      null_resource.role_bindings
    ]
}

# ------------------------------------------------------------------------------
# CDN Related Resources
# ------------------------------------------------------------------------------

resource "google_compute_backend_bucket" "cdn_backend_bucket_vod" {
  name        = "cdn-backend-bucket-vod"
  description = "Backend bucket for serving vod through CDN"
  bucket_name = google_storage_bucket.transcoder_output_bucket.name
  enable_cdn  = true
  project     = var.project_id
}

resource "google_compute_url_map" "cdn_url_map" {
  name            = "cdn-url-map"
  description     = "CDN URL map to cdn_backend_bucket_vod"
  default_service = google_compute_backend_bucket.cdn_backend_bucket_vod.self_link
  project         = var.project_id
}
 
resource "google_compute_target_http_proxy" "cdn_http_proxy" {
  name             = "cdn-http-proxy"
  url_map          = google_compute_url_map.cdn_url_map.self_link
  project          = var.project_id
}

 
resource "google_compute_global_address" "cdn_public_address" {
  name         = "cdn-public-address"
  ip_version   = "IPV4"
  address_type = "EXTERNAL"
  project      = var.project_id
}
 
resource "google_compute_global_forwarding_rule" "cdn_global_forwarding_rule" {
  name       = "cdn-global-forwarding-http-rule"
  target     = google_compute_target_http_proxy.cdn_http_proxy.self_link
  ip_address = google_compute_global_address.cdn_public_address.address
  port_range = "80"
  project    = var.project_id
}

resource "google_storage_bucket_iam_member" "all_users_viewers" {
  bucket = google_storage_bucket.transcoder_output_bucket.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}