const { EC2Client, StartInstancesCommand } = require("@aws-sdk/client-ec2");
const client = new EC2Client();

exports.handler = async () => {
  const command = new StartInstancesCommand({
    InstanceIds: [process.env.INSTANCE_ID]
  });

  try {
    await client.send(command);
    return { statusCode: 200, body: "EC2 starting" };
  } catch (err) {
    return { statusCode: 500, body: JSON.stringify(err) };
  }
};
