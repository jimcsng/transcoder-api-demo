# transcoder-api-demo

This a demo terraform code to create:

1. GCS buckets for the videos to be trancoded and the result
2. A GCF which is triggered by GCS object finalize/create events to kick off the trancoder job
3. CDN and the corresponding load balancer to expose the output bucket as a backend bucket
