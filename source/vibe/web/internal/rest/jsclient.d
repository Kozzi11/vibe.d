module vibe.web.internal.rest.jsclient;

import vibe.web.rest;


/*package(vibe.web.web)*/ void generateInterface(TImpl, R)(ref R output, string name, RestInterfaceSettings settings)
{
	// TODO: handle attributed parameters and filter out internal parameters that have no path placeholder assigned to them

	import std.format : formattedWrite;
	import std.string : toUpper;
	import std.traits : FunctionTypeOf, ReturnType;
	import vibe.data.json : Json, serializeToJson;
	import vibe.internal.meta.uda;
	import vibe.web.internal.rest.common;
	import vibe.web.common;

	auto intf = RestInterface!TImpl(settings);

	output.formattedWrite("%s = new function() {\n", name.length ? name : intf.I.stringof);

	output.put("var toRestString = function(v) { return v; }\n");

	foreach (i, SI; intf.SubInterfaceTypes) {
		output.generateInterface!SI(intf.subInterfaces[i].name, intf.subInterfaces[i].settings);
	}

	foreach (i, F; intf.RouteFunctions) {
		alias FT = FunctionTypeOf!F;
		auto route = intf.routes[i];

		// function signature
		output.formattedWrite("  this.%s = function(", route.functionName);
		foreach (j, param; route.parameters) {
			output.put(param.name);
			output.put(", ");
		}
		static if (!is(ReturnType!FT == void)) output.put("on_result, ");
		output.put("on_error) {\n");

		// url assembly
		if (route.pathHasPlaceholders) {
			output.put("    var url = ");
			output.serializeToJson(intf.baseURL);
			foreach (p; route.pathParts) {
				output.put(" + ");
				if (!p.isParameter) output.serializeToJson(p.text);
				else output.formattedWrite("encodeURIComponent(toRestString(%s))", p.text);
			}
			output.put(";\n");
		} else {
			output.formattedWrite("    var url = %s;\n", Json(concatURL(intf.baseURL, route.pattern)));
		}

		// query parameters
		if (route.queryParameters.length) {
			output.put("    url = url");
			foreach (j, p; route.queryParameters)
				output.formattedWrite(" + \"%s%s=\" + encodeURIComponent(toRestString(%s))",
					j == 0 ? '?' : '&', p.fieldName, p.name);
			output.put(";\n");
		}

		// body parameters
		if (route.bodyParameters.length) {
			output.put("    var postbody = {\n");
			foreach (p; route.bodyParameters)
				output.formattedWrite("      %s: toRestString(%s),\n", Json(p.fieldName), p.name);
			output.put("    };\n");
		}

		// XHR setup
		output.put("    var xhr = new XMLHttpRequest();\n");
		output.formattedWrite("    xhr.open('%s', url, true);\n", route.method.to!string.toUpper);
		static if (!is(RT == void)) {
			output.put("    xhr.onload = function () { if (this.status >= 400) { if (on_error) on_error(JSON.parse(this.responseText)); else console.log(this.responseText); } else on_result(JSON.parse(this.responseText)); };\n");
		}

		// header parameters
		foreach (p; route.headerParameters)
			output.formattedWrite("    xhr.setRequestHeader(%s, %s);\n", Json(p.fieldName), p.name);

		// submit request
		if (route.method == HTTPMethod.GET)
			output.put("    xhr.send();\n");
		else {
			output.put("    xhr.setRequestHeader('Content-Type', 'application/json');\n");
			output.put("    xhr.send(JSON.stringify(postbody));\n");
		}

		output.put("  }\n\n");
	}

	output.put("}\n");
}

version (unittest) {
	interface IDUMMY {}
	class DUMMY : IDUMMY {}
	private void dummy()
	{
		import std.array;
		auto app = appender!string();
		app.generateInterface!DUMMY(null, null);
	}
}
