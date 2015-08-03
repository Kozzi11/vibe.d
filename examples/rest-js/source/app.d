import vibe.d;

interface ITest {
	@method(HTTPMethod.GET)
	float computeSum(float a, float b);
	void postToConsole(string text);
}

class Test : ITest {
	import std.stdio;
	float computeSum(float a, float b) { return a + b; }
	void postToConsole(string text) { writeln(text); }
}

shared static this()
{
	auto restsettings = new RestInterfaceSettings;
	restsettings.baseURL = URL("http://127.0.0.1:8080/");

	auto router = new URLRouter;
	router.get("/test.js", serveRestJSClient!Test(restsettings));
	router.get("/", staticTemplate!"index.dt");
	router.registerRestInterface(new Test, restsettings);

	auto settings = new HTTPServerSettings;
	settings.port = 8080;
	settings.bindAddresses = ["::1", "127.0.0.1"];
	listenHTTP(settings, router);

	logInfo("Please open http://127.0.0.1:8080/ in your browser.");
}
