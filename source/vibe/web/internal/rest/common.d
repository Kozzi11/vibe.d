module vibe.web.internal.rest.common;

import vibe.web.rest;


/**
	Provides all necessary tools to implement an automated REST interface.

	The given `TImpl` must be an `interface` or a `class` deriving from one.
*/
/*package(vibe.web.web)*/ struct RestInterface(TImpl)
{
	import std.traits : FunctionTypeOf, InterfacesTuple, MemberFunctionsTuple,
		ParameterIdentifierTuple, ParameterStorageClass,
		ParameterStorageClassTuple, ParameterTypeTuple, ReturnType;
	import std.typetuple : TypeTuple;
	import vibe.inet.url : URL;
	import vibe.internal.meta.funcattr;
	import vibe.internal.meta.uda;

	/// The settings used to generate the interface
	RestInterfaceSettings settings;

	/// Full base path of the interface, including an eventual `@path` annotation.
	string basePath;

	/// Full base URL of the interface, including an eventual `@path` annotation.
	string baseURL;

	// determine the implementation interface I and check for validation errors
	private alias BaseInterfaces = InterfacesTuple!TImpl;
	static assert (BaseInterfaces.length > 0 || is (TImpl == interface),
		       "Cannot registerRestInterface type '" ~ TImpl.stringof
		       ~ "' because it doesn't implement an interface");
	static if (BaseInterfaces.length > 1)
		pragma(msg, "Type '" ~ TImpl.stringof ~ "' implements more than one interface: make sure the one describing the REST server is the first one");


	static if (is(TImpl == interface))
		alias I = TImpl;
	else
		alias I = BaseInterfaces[0];
	static assert(getInterfaceValidationError!I is null, getInterfaceValidationError!(I));

	/// The name of each interface member
	enum memberNames = [__traits(allMembers, I)];

	/// Aliases to all interface methods
	alias AllMethods = GetAllMethods!();

	/** Information about each route

		This array has the same number of fields as `RouteFunctions`
	*/
	Route[] routes;

	/** Aliases for each route method

		This tuple has the same number of entries as `routes`.
	*/
	alias RouteFunctions = GetRouteFunctions!();

	/** Information about sub interfaces

		This array has the same number of entries as `SubInterfaceFunctions` and
		`SubInterfaceTypes`.
	*/
	SubInterface[] subInterfaces;

	/** Aliases for each sub interface method

		This array has the same number of entries as `subInterfaces` and
		`SubInterfaceTypes`.
	*/
	alias SubInterfaceFunctions = GetSubInterfaceFunctions!();

	/** The type of each sub interface

		This array has the same number of entries as `subInterfaces` and
		`SubInterfaceFunctions`.
	*/
	alias SubInterfaceTypes = GetSubInterfaceTypes!();


	/** Fills the struct with information.

		Params:
			settings = Optional settings object.
	*/
	this(RestInterfaceSettings settings)
	{
		import vibe.internal.meta.uda : findFirstUDA;

		this.settings = settings ? settings.dup : new RestInterfaceSettings;
		this.basePath = this.settings.baseURL.path.toString();

		enum uda = findFirstUDA!(PathAttribute, I);
		static if (uda.found) {
			static if (uda.value.data == "") {
				auto path = "/" ~ adjustMethodStyle(I.stringof, this.settings.methodStyle);
				this.basePath = concatURL(this.basePath, path);
			} else {
				this.basePath = concatURL(this.basePath, uda.value.data);
			}
		}
		URL bu = this.settings.baseURL;
		bu.pathString = this.basePath;
		this.baseURL = bu.toString();

		computeRoutes();
		computeSubInterfaces();
	}

	private void computeRoutes()
	{
		assert(routes.length == 0);

		foreach (func; RouteFunctions) {
			Route route;
			route.functionName = __traits(identifier, func);

			alias FuncType = FunctionTypeOf!func;
			alias ParameterTypes = ParameterTypeTuple!FuncType;
			alias ReturnType = std.traits.ReturnType!FuncType;
			enum parameterNames = [ParameterIdentifierTuple!func];

			enum meta = extractHTTPMethodAndName!(func, false)();
			static if (meta.hadPathUDA) route.pattern = meta.url;
			else route.pattern = adjustMethodStyle(stripTUnderscore(meta.url, settings), settings.methodStyle);
			route.method = meta.method;

			extractPathParts(route);

			foreach (i, PT; ParameterTypes) {
				enum pname = parameterNames[i];
				alias WPAT = UDATuple!(WebParamAttribute, func);

				// Comparison template for anySatisfy
				//template Cmp(WebParamAttribute attr) { enum Cmp = (attr.identifier == ParamNames[i]); }
				alias CompareParamName = GenCmp!("Loop", i, parameterNames[i]);
				mixin(CompareParamName.Decl);

				ParameterInfo pi;
				pi.name = parameterNames[i];

				// determine in/out storage class
				foreach (SC; ParameterStorageClassTuple!func) {
					static if (SC & ParameterStorageClass.out_) {
						pi.isOut = true;
					} else static if (SC & ParameterStorageClass.ref_) {
						pi.isIn = true;
						pi.isOut = true;
					} else {
						pi.isIn = true;
					}
				}

				// determine parameter source/destination
				if (IsAttributedParameter!(func, pname)) {
					pi.kind = ParameterKind.attributed;
				} else static if (anySatisfy!(mixin(CompareParamName.Name), WPAT)) {
					alias PWPAT = Filter!(mixin(CompareParamName.Name), WPAT);
					final switch (PWPAT[0].origin) with (WebParamAttribute.Origin) {
						case Header: pi.kind = ParameterKind.header; break;
						case Query: pi.kind = ParameterKind.query; break;
						case Body: pi.kind = ParameterKind.body_; break;
					}
					pi.fieldName = PWPAT[0].field;
				} else static if (pname.startsWith("_")) {
					pi.kind = ParameterKind.internal;
					pi.fieldName = parameterNames[i][1 .. $];
				} else static if (i == 0 && pname == "id") {
					pi.kind = ParameterKind.internal;
					pi.fieldName = "id";
					route.pattern = concatURL(":id", route.pattern);
					route.pathParts = PathPart(true, "id") ~ route.pathParts;
					route.pathHasPlaceholders = true;
				} else {
					pi.kind = route.method == HTTPMethod.GET ? ParameterKind.query : ParameterKind.body_;
					pi.fieldName = stripTUnderscore(pname, settings);
				}

				route.parameters ~= pi;
				final switch (pi.kind) {
					case ParameterKind.query: route.queryParameters ~= pi; break;
					case ParameterKind.body_: route.bodyParameters ~= pi; break;
					case ParameterKind.header: route.headerParameters ~= pi; break;
					case ParameterKind.internal: route.internalParameters ~= pi; break;
					case ParameterKind.attributed: route.attributedParameters ~= pi; break;
				}
			}

			route.fullPattern = concatURL(this.basePath, route.pattern);

			routes ~= route;
		}

		assert(routes.length == RouteFunctions.length);
	}

	private void computeSubInterfaces()
	{
		assert(subInterfaces.length == 0);

		foreach (func; SubInterfaceFunctions) {
			enum meta = extractHTTPMethodAndName!(func, false)();

			static if (meta.hadPathUDA) string url = meta.url;
			else string url = adjustMethodStyle(stripTUnderscore(meta.url, settings), settings.methodStyle);

			SubInterface si;
			si.settings = settings.dup;
			si.settings.baseURL = URL(concatURL(this.baseURL, url, true));
			subInterfaces ~= si;
		}

		assert(subInterfaces.length == SubInterfaceFunctions.length);
	}

	private template GetSubInterfaceFunctions() {
		template Impl(size_t idx) {
			static if (idx < AllMethods.length) {
				alias R = ReturnType!(AllMethods[idx]);
				static if (is(R == interface)) {
					alias Impl = TypeTuple!(AllMethods[idx], Impl!(idx+1));
				} else {
					alias Impl = Impl!(idx+1);
				}
			} else alias Impl = TypeTuple!();
		}
		alias GetSubInterfaceFunctions = Impl!0;
	}

	private template GetSubInterfaceTypes() {
		template Impl(size_t idx) {
			static if (idx < AllMethods.length) {
				alias R = ReturnType!(FunctionTypeOf!(AllMethods[idx]));
				static if (is(R == interface)) {
					alias Impl = TypeTuple!(R, Impl!(idx+1));
				} else {
					alias Impl = Impl!(idx+1);
				}
			} else alias Impl = TypeTuple!();
		}
		alias GetSubInterfaceTypes = Impl!0;
	}

	private template GetRouteFunctions() {
		template Impl(size_t idx) {
			static if (idx < AllMethods.length) {
				alias F = AllMethods[idx];
				static if (!is(ReturnType!(FunctionTypeOf!F) == interface))
					alias Impl = TypeTuple!(F, Impl!(idx+1));
				else alias Impl = Impl!(idx+1);
			} else alias Impl = TypeTuple!();
		}
		alias GetRouteFunctions = Impl!0;
	}

	private template GetAllMethods() {
		template Impl(size_t idx) {
			static if (idx < memberNames.length) {
				enum name = memberNames[idx];
				// WORKAROUND #1045 / @@BUG14375@@
				static if (name.length != 0)
					alias Impl = TypeTuple!(MemberFunctionsTuple!(I, name), Impl!(idx+1));
				else alias Impl = Impl!(idx+1);
			} else alias Impl = TypeTuple!();
		}
		alias GetAllMethods = Impl!0;
	}
}

struct Route {
	string functionName; // D name of the function
	string pattern; // relative route path (relative to baseURL)
	string fullPattern; // absolute version of 'pattern'
	bool pathHasPlaceholders; // true if path/pattern contains any :placeholers
	PathPart[] pathParts; // path separated into text and placeholder parts
	HTTPMethod method;
	ParameterInfo[] parameters;
	ParameterInfo[] queryParameters;
	ParameterInfo[] bodyParameters;
	ParameterInfo[] headerParameters;
	ParameterInfo[] attributedParameters;
	ParameterInfo[] internalParameters;
}

struct PathPart {
	/// interpret `text` as a parameter name (including the leading underscore) or as raw text
	bool isParameter;
	string text;
}

struct ParameterInfo {
	ParameterKind kind;
	string name;
	string fieldName;
	bool isIn;
	bool isOut;
}

enum ParameterKind {
	query,       // req.query[]
	body_,       // JSON body
	header,      // req.header[]
	attributed,  // @before
	internal     // req.params[]
}

struct SubInterface {
	RestInterfaceSettings settings;
}

private void extractPathParts(ref Route route)
{
	import std.string : indexOf;

	string p = route.pattern;

	while (p.length) {
		auto cidx = p.indexOf(':');
		if (cidx < 0) break;
		if (cidx > 0) route.pathParts ~= PathPart(false, p[0 .. cidx]);
		p = p[cidx+1 .. $];

		auto sidx = p.indexOf('/');
		if (sidx < 0) sidx = p.length;
		assert(sidx > 0, "Empty path placeholders are illegal.");
		route.pathParts ~= PathPart(true, "_" ~ p[0 .. sidx]);
		route.pathHasPlaceholders = true;
	}

	if (p.length) route.pathParts ~= PathPart(false, p);
}

unittest {
	interface IDUMMY {}
	class DUMMY : IDUMMY {}
	auto test = RestInterface!DUMMY(null);
}