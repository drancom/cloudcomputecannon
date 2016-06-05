package ccc.compute;

import ccc.compute.Definitions;
import ccc.compute.Definitions.Constants.*;
import ccc.compute.server.ServerCommands;
import ccc.storage.ServiceStorage;

import haxe.Json;

import js.node.http.*;
import js.node.http.ServerResponse;
import js.npm.RedisClient;

import util.DockerTools;
import util.streams.StreamTools;

class ServiceRegistry
{
	@inject public var _fs :ServiceStorage;
	@inject public var _redis :RedisClient;

	public function new() {}

	public function router() :js.node.express.Router
	{
		var router = js.node.express.Express.GetRouter();
		router.post('/build/*', buildDockerImageRouter);
		return router;
	}

	function buildDockerImageRouter(req :IncomingMessage, res :ServerResponse, next :?Dynamic->Void) :Void
	{
		var isFinished = false;
		res.on(ServerResponseEvent.Finish, function() {
			isFinished = true;
		});
		function returnError(err :String, ?statusCode :Int = 400) {
			Log.error(err);
			if (isFinished) {
				Log.error('Already returned ');
				Log.error(err);
			} else {
				isFinished = true;
				res.setHeader("content-type","application/json-rpc");
				res.writeHead(statusCode);
				res.end(Json.stringify({
					error: err
				}));
			}
		}

		var repositoryString :String = untyped req.params[0];

		if (repositoryString == null) {
			returnError('You must supply a docker repository after ".../build/"', 400);
			return;
		}

		var repository :DockerUrl = repositoryString;

		try {
			if (repository.name == null) {
				returnError('You must supply a docker repository after ".../build/"', 400);
				return;
			}
			if (repository.tag == null) {
				returnError('All images must have a tag', 400);
				return;
			}
		} catch (err :Dynamic) {
			returnError(err, 500);
			return;
		}

		res.on('error', function(err) {
			Log.error({error:err});
		});
		res.writeHead(200);
		var throughStream = StreamTools.createTransformStream(function(chunk, encoding, forwarder) {
			res.write(chunk);
			forwarder(null, chunk);
		});
		ServerCommands.buildImageIntoRegistry(req, repository, throughStream)
			.then(function(imageUrl) {
				isFinished = true;
				res.end(Json.stringify({image:imageUrl}), 'utf8');
			})
			.catchError(function(err) {
				returnError('Failed to build image err=$err', 500);
			});
	}
}