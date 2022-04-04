// Imports the Transcoder library
const {TranscoderServiceClient} =
require('@google-cloud/video-transcoder').v1;
const { v4: uuidv4 } = require('uuid');

/**
* Triggered from a change to a Cloud Storage bucket.
*
* @param {!Object} event Event payload.
* @param {!Object} context Metadata for the event.
*/
exports.createTranscodeJob = async (event, context) => {
const gcsEvent = event;
console.log(`Processing file: ${JSON.stringify(gcsEvent)}`);

projectId = process.env.PROJ_ID
location = process.env.TRANSCODER_LOC
inputUri = `gs://${gcsEvent.bucket}/${gcsEvent.name}`
outputUri = `gs://${process.env.OUTPUT_BUCKET}/${uuidv4()}/`
preset = 'preset/web-hd';

// Instantiates a client
const transcoderServiceClient = new TranscoderServiceClient();

async function createJobFromPreset() {
// Construct request
const request = {
  parent: transcoderServiceClient.locationPath(projectId, location),
  job: {
    inputUri: inputUri,
    outputUri: outputUri,
    templateId: preset,
  },
};

// Run request
const [response] = await transcoderServiceClient.createJob(request);
const jobFullName = response.name
console.log(`Job ${jobFullName} created`)
return jobFullName.substring(jobFullName.lastIndexOf("/") + 1, jobFullName.length)
}

async function waitForJob(jobId) {
const t = setInterval(async function() {
  const request = {
    name: transcoderServiceClient.jobPath(projectId, location, jobId),
  };
  const [response] = await transcoderServiceClient.getJob(request);
  console.log(`Job ${jobId} status is ${response.state}`)
  if (response.state == 'SUCCEEDED' || response.state == 'FAILED') {
    console.log(`Job ${jobId} result is:\n ${JSON.stringify(response)}`)
    clearInterval(this)
  }
}, 1500)
}

const jobId = await createJobFromPreset()
await waitForJob(jobId)

return
};
