import vibe.d;
import std.typecons;

import nwn2.character;


private string implementJsonIface(API)(){
	import std.traits;
	import std.meta : AliasSeq;
	import std.string : format;
	string ret;

	foreach(member ; __traits(allMembers, API)){
		static if(__traits(getProtection, mixin("API."~member))=="package"
			&& isCallable!(mixin("API."~member))
			&& member[0]=='_'){

			enum attributes = __traits(getFunctionAttributes, mixin("API."~member));
			alias UDAs = AliasSeq!(__traits(getAttributes, mixin("API."~member)));
			alias ParamNames = ParameterIdentifierTuple!(mixin("API."~member));
			alias ParamTypes = Parameters!(mixin("API."~member));
			alias Return = ReturnType!(mixin("API."~member));

			enum paramTypes = ParamTypes.stringof[1..$-1].split(", ");

			//UDAs
			foreach(uda ; UDAs)
				ret ~= "@"~uda.stringof~" ";
			ret ~= "\n";
			//Return type
			static if(is(Return==void))
				ret ~= "void ";
			else
				ret ~= "Json ";
			//Name
			ret ~= member[1..$];
			//Parameters
			ret ~= "(";
			static if(ParamNames.length>0){
				foreach(i, name ; ParamNames){
					static if(i>0) ret ~= ", ";
					ret ~= paramTypes[i]~" "~name;
				}
			}
			ret ~= ") ";
			//Function attributes
			ret ~= [attributes].join(" ")~"{\n";
			//Body
			ret ~= "\treturn this."~member~"(";
			static if(ParamNames.length>0)
				ret ~= [ParamNames].join(", ");
			ret ~= ")";
			//Body - Serialization
			static if(!is(Return==void))
				ret ~= ".serializeToJson()";
			ret ~= ";\n";
			//end
			ret ~= "}\n";
		}

	}
	return ret;
}
/// Json API
///    /api/login login password
///    /api/logout
///    /api/:account/characters/list
///    /api/:account/characters/:char/
///    /api/:account/characters/:char/delete
///  - /api/:account/characters/:char/undelete
///    /api/:account/characters/deleted/:char/
///  - /api/:account/characters/deleted/:char/undelete
///
@path("/api")
class Api{

	mixin(implementJsonIface!Api);


package:
	alias CharList = Tuple!(Character[],"active",Character[],"deleted");

	@path("/:account/characters/list")
	CharList _getCharList(string _account){
		//enforceHTTP(req.session, HTTPStatus.unauthorized);
		//enforceHTTP(authenticated, HTTPStatus.unauthorized);
		//enforceHTTP(admin || _account==account, HTTPStatus.forbidden);
		//enforceHTTP(req.session.get!bool("isAdmin") || _account==session.get!string("account"), HTTPStatus.forbidden);

		//TODO: what if _account="../../secureThing" ?

		import std.file : DirEntry, dirEntries, SpanMode, exists, isDir;
		import std.path : buildNormalizedPath;
		import std.algorithm : sort;

		auto activeVault = DirEntry(buildNormalizedPath(
				"/home/crom/Documents/Neverwinter Nights 2/servervault/",//TODO: get from config
				_account));

		auto activeChars = activeVault
				.dirEntries("*.bic", SpanMode.shallow)
				.map!(a => new Character(a))
				.array
				.sort!"a.name<b.name"
				.array;

		auto deletedVaultPath = buildNormalizedPath(activeVault, "deleted");
		Character[] deletedChars = null;
		if(deletedVaultPath.exists && deletedVaultPath.isDir){
			deletedChars = DirEntry(deletedVaultPath)
					.dirEntries("*.bic", SpanMode.shallow)
					.map!(a => new Character(a))
					.array
					.sort!"a.name<b.name"
					.array;
		}

		return CharList(activeChars, deletedChars);
	}
	@path("/:account/characters/:char")
	Character _getActiveCharInfo(string _account, string _char){
		//enforceHTTP(authenticated, HTTPStatus.forbidden);
		//enforceHTTP(admin || _account==account, HTTPStatus.forbidden);
		return getCharInfo(_account, _char);
	}
	@path("/:account/characters/deleted/:char")
	Character _getDeletedCharInfo(string _account, string _char){
		//enforceHTTP(authenticated, HTTPStatus.forbidden);
		//enforceHTTP(admin || _account==account, HTTPStatus.forbidden);
		return getCharInfo(_account, _char, true);
	}
	@path("/:account/characters/:char/delete")
	void _postDeleteChar(string _account, string _char){
		import std.file : exists, isDir, rename, mkdir;
		import std.path : buildNormalizedPath;

		auto accountVault = buildNormalizedPath(
			"/home/crom/Documents/Neverwinter Nights 2/servervault/",
			_account);

		auto deletedFolder = buildNormalizedPath(accountVault, "deleted");

		if(!deletedFolder.exists){
			mkdir(deletedFolder);
		}


		auto target = buildNormalizedPath(deletedFolder, _char~".bic");
		if(target.exists){
			import std.regex : ctRegex, matchFirst;
			enum rgx = ctRegex!r"^(.+?)(\d*)$";
			auto match = _char.matchFirst(rgx);
			if(match.empty)throw new Exception("Unable to parse character name: "~_char);

			string newName = match[1];
			int index = match[2].to!int;

			while(target.exists){
				target = buildNormalizedPath(deletedFolder, newName~(++index).to!string~".bic");
			}
		}

		import std.stdio : writeln;
		writeln("Renaming '",accountVault,"' to '",target,"'");
		rename(accountVault, target);
	}

	void _postLogin(string login, string password){
		import mysql;
		import nwn2.resman;
		import app : ConnectionWrap;
		auto conn = ResMan.get!ConnectionWrap("sql");

		//TODO: move query to settings?
		//TODO: Check if fields are correctly escaped
		bool credsOK;
		conn.execute("SELECT (`password`=SHA(?)) FROM `account` WHERE `name`=?", password, login, (MySQLRow row){
			credsOK = row[0].get!int == 1;
		});

		enforceHTTP(credsOK, HTTPStatus.forbidden);

		//session = startSession();
		//authenticated = true;
		//account = login;
	}
	void _postLogout(){
		terminateSession();
	}

private:
	SessionVar!(bool, "authenticated") authenticated;
	SessionVar!(bool, "admin") admin;
	SessionVar!(string, "account") account;


	Character getCharInfo(in string account, in string bicName, bool deleted=false){
		import std.file : DirEntry;
		import std.path : buildNormalizedPath;

		return new Character(DirEntry(buildNormalizedPath(
			"/home/crom/Documents/Neverwinter Nights 2/servervault/",//TODO: get from config
			account,
			deleted? "deleted" : "",
			bicName~".bic"
			)));
	}


}