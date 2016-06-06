package ccc.compute;

import ccc.compute.Definitions;
import ccc.compute.Definitions.Constants.*;
import ccc.compute.server.ServerCommands;
import ccc.storage.ServiceStorage;

import haxe.DynamicAccess;
import haxe.Json;

import js.node.http.*;
import js.node.http.ServerResponse;
import js.npm.RedisClient;

import promhx.Promise;

import t9.abstracts.net.*;

import util.DockerTools;
import util.DockerRegistryTools;
import util.streams.StreamTools;

/**
 * Rest API and other internal tools for uploading and managing
 * docker images defined by jobs and used by workers.
 */
class ServiceRegistry
{
	// @inject public var _fs :ServiceStorage;
	// @inject public var _redis :RedisClient;

	@rpc({
		alias:'image-exists',
		doc:'Checks if a docker image exists in the registry'
	})
	public function imageExistsInLocalRegistry(image :DockerUrl) :Promise<Bool>
	{
		var repository = image.repository;
		var tag = image.tag;
		var host :Host = ConnectionToolsRegistry.getRegistryAddress();
		trace('imageExistsInLocalRegistry image=$image repository=$repository tag=$tag host=$host');
		return DockerRegistryTools.isImageIsRegistry(host, repository, tag);
	}

	@rpc({
		alias:'images',
		doc:'Checks if a docker image exists in the registry'
	})
	public function getAllImagesInRegistry() :Promise<DynamicAccess<Array<String>>>
	{
		var host :Host = ConnectionToolsRegistry.getRegistryAddress();
		return DockerRegistryTools.getRegistryImagesAndTags(host);
	}

	public function getCorrectImageUrl(url :DockerUrl) :Promise<DockerUrl>
	{
		return getFullDockerImageRepositoryUrl(url);
	}

	/**
	 * If the docker image repository looks like 'myname/myimage', it might
	 * be an image actually already uploaded to the registry. However, workers
	 * need the full URL to the registry e.g. "<ip>:5001/myname/myimage".
	 * This function checks if the image is in the repository, and if so,
	 * ensures the host is part of the full URL.
	 * @param  url :DockerUrlBlob [description]
	 * @return     [description]
	 */
	public function getFullDockerImageRepositoryUrl(url :DockerUrl) :Promise<DockerUrl>
	{
		trace('getFullDockerImageRepositoryUrl url=$url');
		if (url.registryhost != null) {
			return Promise.promise(url);
		} else {
			return imageExistsInLocalRegistry(url)
				.then(function(exists) {
					if (!exists) {
						trace('getFullDockerImageRepositoryUrl url=$url exists=$exists');
						return url;
					} else {
						var registryHost :Host = ConnectionToolsRegistry.getRegistryAddress();
						url.registryhost = registryHost;
						trace('getFullDockerImageRepositoryUrl url=$url exists=$exists');
						return url;
					}
				});
		}
	}

	public function router() :js.node.express.Router
	{
		var router = js.node.express.Express.GetRouter();
		router.post('/build/*', buildDockerImageRouter);
		router.get('/exists/*', buildDockerImageRouter);
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

	public function new() {}
}