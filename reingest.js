/*
Lambda function for reading from Firehose's "Splashback" Backup S3 Bucket.
Function will read from S3 and write back to Firehose.
Ensure that the appropriate lambda function is enabled on the Firehose,
otherwise the events will lose "source" and
also potentially continiously loop if no connection to HEC is restored
Function will Drop any unsent Events back into the ORIGINATING S3 Bucket. (after timeout)
Uses 4 Environment variables - REGION, FIREHOSE_DEST, MAX_REINGEST, S3_FAILED_PREFIX
*/

const zlib = require('zlib');
const aws = require('aws-sdk');
const { config } = require('./config');
const { retry } = require('./retry');

exports.handler = (event, _, callback) => {
  safeLogJson(console.debug, event);
  const bucket = event.Records[0].s3.bucket.name;
  const { key } = event.Records[0].s3.object;
  let recordBatch = [];
  const s3payload = {
    failedRecords: [],
  };
  if (!config.firehoseDest) throw 'FIREHOSE environment variable not set!';
  if (!config.s3FailedPrefix) throw 'S3_FAILED_PREFIX environment variable not set!';

  const fhClient = new aws.Firehose({ region: config.region });
  const s3Client = new aws.S3();

  const getObjParams = {
    Bucket: bucket,
    Key: key,
  };
  console.info(`Attempting reingestion on ${key}`);
  console.debug("Getting object from S3", getObjParams);
  s3Client.getObject(getObjParams).promise().then(async (data) => {
    console.debug("Successfully retrieved data from S3");
    const buffer = data.Body;
    let decompressed;
    try { // Assume data is gzip
      console.debug("Attempting to decompress using gzip.");
      decompressed = zlib.gunzipSync(buffer).toString().trim();
    } catch (e) {
      console.warn("Failed to decompress using gzip. Falling back to plain text.");
      decompressed = buffer.toString().trim();
    }

    decompressed.split('\n').forEach(async (line) => { // process every "batch"
      if (line.length > 0) {
        try {
          const lineData = JSON.parse(line);
          const base64Message = lineData.rawData;
          const decodedMessage = Buffer.from(base64Message, 'base64').toString();
          const reingestionEvents = [];
          decodedMessage.trim().split('\n').forEach((messageLine) => { // process every line of the batch
            let messageEvent = {};
            try {
              messageEvent = JSON.parse(messageLine);
            } catch (e) {
              console.error('Failed to parses line as JSON', messageLine);
              throw e;
            }
            let ingestionCount = 1;
            if (messageEvent.hasOwnProperty('fields') && messageEvent.fields.hasOwnProperty(config.reingestionKey))
              ingestionCount = messageEvent.fields[config.reingestionKey] + 1;
            if (!messageEvent.hasOwnProperty('fields'))
              messageEvent.fields = {};

            if (ingestionCount > config.maxReingest) {
              s3payload.failedRecords.push(messageEvent);
            } else {
              messageEvent.fields[config.reingestionKey] = ingestionCount;
              reingestionEvents.push(messageEvent);
            }
          });
          if (reingestionEvents.length != 0) {
            recordBatch.push({ Data: JSON.stringify(reingestionEvents) });
            if (recordBatch.length > 499) { // Max 500 records can be ingested by firehose at a time
              const params = {
                DeliveryStreamName: config.firehoseDest,
                Records: recordBatch,
              };
              await retry(() => fhClient.putRecordBatch(params).promise(), 20);
              console.debug('Reingested 500/500 records to the stream %s', config.firehoseDest);
              recordBatch = [];
            }
          }
        } catch (error) {
          console.error(error, error.stack);
          s3payload.failedRecords.push(line);
        }
      }
    });
    if (recordBatch.length != 0) { // Send any remaining records
      const totalRecordsLeftToBeIngested = recordBatch.length;
      const params = {
        DeliveryStreamName: config.firehoseDest,
        Records: recordBatch,
      };
      await retry(() => fhClient.putRecordBatch(params).promise(), 20);
      recordBatch = [];
      console.debug('Reingested %s/%s records to the stream %s', totalRecordsLeftToBeIngested, totalRecordsLeftToBeIngested, config.firehoseDest);
    }
    if (s3payload.failedRecords.length > 0) { // Send any failed records to s3 with stale prefix.
      console.warn('%s records exceeded max re-ingestion attempts or failed to be resent to delivery stream. Dumping into s3 prefix %s', s3payload.failedRecords.length, config.s3FailedPrefix);
      const s3Path = config.s3FailedPrefix + key;
      const putObjectParams = {
        Bucket: bucket,
        Key: s3Path,
        Body: JSON.stringify(s3payload.failedRecords),
        ContentType: 'application/json',
      };
      await s3Client.putObject(putObjectParams).promise();
      console.warn('Successfully uploaded failed records to %s/%s.', bucket, s3Path);
    }
    console.debug('Deleting original record object %s/%s', bucket, key);
    const deleteParams = {
      Bucket: bucket,
      Key: key,
    };
    await s3Client.deleteObject(deleteParams).promise();
    console.debug('Successfully deleted original record object %s/%s', bucket, key);
  }).catch((err) => {
    console.error('Failed to retrieve data from s3', err, err.stack);
    callback(err, { success: false, error: err });
  });

  console.info(`Successfully completed reingestion on ${key}`);
  callback(null, { success: true });
};

function safeLogJson(logFunc, obj) {
  try {
    logFunc(JSON.stringify(obj));
  } catch (e) {
    console.error("Unable to log JSON", obj, e);
  }
}
