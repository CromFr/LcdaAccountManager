module api.vault;

import vibe.d;
debug import std.stdio: writeln;
import std.file;
import std.path;

import nwn.fastgff;
import nwn.tlk;
import nwn.twoda;

import sql;
import lcda.character;
import api.api;
import api.apidef;
import vibe.web.auth;
import resourcemanager: ResourceManager, ResourceException;

class CharListCache{
	ulong hash;
	LightCharacter[] data;
}

@requiresAuth
class Vault(bool deletedChar): IVault!deletedChar{
	this(Api api){
		this.api = api;

		auto conn = api.mysqlConnPool.lockConnection();

		foreach(ref query ; api.cfg["sql_queries"]["on_activate"].get!(Json[])){
			prepOnDelete ~= conn.prepareCustom(query.get!string, ["ACCOUNT", "CHAR"]);
		}
		foreach(ref query ; api.cfg["sql_queries"]["on_delete"].get!(Json[])){
			prepOnDelete ~= conn.prepareCustom(query.get!string, ["ACCOUNT", "CHAR"]);
		}
	}
	private{
		PreparedCustom[] prepOnActivate;
		PreparedCustom[] prepOnDelete;
	}

	override{
		UserInfo authenticate(scope HTTPServerRequest req, scope HTTPServerResponse res) @safe{
			return api.authenticate(req, res);
		}


		LightCharacter[] list(string _account) @trusted{
			import std.algorithm: sort, map;
			import std.array: array;

			immutable vaultPath = getVaultPath(_account, deletedChar);

			static if(deletedChar == false){
				enforceHTTP(vaultPath.exists && vaultPath.isDir, HTTPStatus.notFound,
					"Account / Vault not found");
			}
			else{
				auto activeVaultPath = getVaultPath(_account, false);
				enforceHTTP(activeVaultPath.exists && activeVaultPath.isDir, HTTPStatus.notFound,
					"Account / Vault not found");

				if(!vaultPath.exists){
					return [];
				}
			}

			static struct CachedList{
				this() @disable;
				this(in string vaultPath, LightCharacter[] list){
					this.vaultPath = vaultPath;
					this.list = list;
					hash = calcHash();
				}
				string vaultPath;
				LightCharacter[] list;

				ulong hash;
				ulong calcHash() const{
					return vaultPath
						.dirEntries("*.bic*", SpanMode.shallow)
						.map!((file){
							import std.conv: to;
							SysTime acc, mod;
							file.getTimes(acc, mod);
							return file.name~"="~acc.to!string;
						})
						.join(":")
						.hashOf;
				}
			}

			import cache: Cache;
			//TODO: this cast is awful but should not be a problem
			return cast(LightCharacter[]) Cache.get!(const CachedList)(vaultPath,
				function(in CachedList rec, lastAccess){
					return !rec.vaultPath.exists
					|| rec.hash != rec.calcHash();
				},
				delegate(){
					scope(success){
						import std.stdio : writeln, stdout;
						writeln("Generated character list ", _account ~ (deletedChar ? "/deleted" : null));
						stdout.flush();
					}
					return CachedList(vaultPath,
						vaultPath.dirEntries("*.bic", SpanMode.shallow)
						         .map!(a => buildLightCharacter(a, true))
						         .array
						         .sort!"a.name<b.name"
						         .array);
				}).list;
		}

		Character character(string _account, string _char) @trusted{
			import cache;

			immutable file = getCharPath(_account, _char, deletedChar);
			enforceHTTP(file.exists && file.isFile, HTTPStatus.notFound,
				"Character '"~_char~"' not found");

			static struct CachedCharacter{
				string filePath;
				SysTime lastModified;
				Character character;
			}

			//TODO: this cast is awful but should not be a problem
			return cast(Character) Cache.get!(const CachedCharacter)(file,
				function(in CachedCharacter rec, created){
					return !rec.filePath.exists
					|| rec.filePath.timeLastModified > rec.lastModified
					|| (Clock.currTime() - created) > dur!"minutes"(5);
				},
				delegate(){
					scope(success){
						import std.stdio : writeln, stdout;
						writeln("Generated character info ", _account ~ (deletedChar ? "/deleted/" : "/") ~ _char);
						stdout.flush();
					}
					return CachedCharacter(
						file,
						file.timeLastModified,
						getChar(_account, _char, deletedChar));
				}).character;
		}


		void downloadChar(string _account, string _char, HTTPServerRequest req, HTTPServerResponse res){
			immutable charFile = getCharPath(_account, _char, deletedChar);
			enforceHTTP(charFile.exists && charFile.isFile, HTTPStatus.notFound,
				"Character '"~charFile~"' not found");

			res.headers["Content-Disposition"] = "filename=\"" ~ charFile.baseName ~ "\"";
			serveStaticFile(charFile)(req, res);
		}

		Item[string] equipment(string _account, string _char) @trusted {
			immutable file = getCharPath(_account, _char, deletedChar);
			enforceHTTP(file.exists && file.isFile, HTTPStatus.notFound,
				"Character '"~_char~"' not found");

			Item[string] ret;

			auto gff = new FastGff(file);
			foreach(_, itemGff ; gff["Equip_ItemList"].get!GffList){

				string slotName;
				switch(itemGff.id){
					case 2^^0:  slotName = "head"; break;
					case 2^^1:  slotName = "chest"; break;
					case 2^^2:  slotName = "boots"; break;
					case 2^^3:  slotName = "arms"; break;
					case 2^^4:  slotName = "rhand"; break;
					case 2^^5:  slotName = "lhand"; break;
					case 2^^6:  slotName = "cloak"; break;
					case 2^^7:  slotName = "lring"; break;
					case 2^^8:  slotName = "rring"; break;
					case 2^^9:  slotName = "neck"; break;
					case 2^^10: slotName = "belt"; break;
					case 2^^11: slotName = "arrows"; break;
					case 2^^12: slotName = "bullets"; break;
					case 2^^13: slotName = "bolts"; break;
					default: continue;
				}

				ret[slotName] = gffToItem(itemGff);

			}
			return ret;
		}

		Item[] inventory(string _account, string _char) @trusted {
			immutable file = getCharPath(_account, _char, deletedChar);
			enforceHTTP(file.exists && file.isFile, HTTPStatus.notFound,
				"Character '"~_char~"' not found");


			Item[] ret;

			auto gff = new FastGff(file);
			foreach(_, itemGff ; gff["ItemList"].get!GffList){
				ret ~= gffToItem(itemGff);

				auto list = "ItemList" in itemGff;
				if(!list.isNull){
					foreach(_, itemGff ; list.get.get!GffList){
						ret ~= gffToItem(itemGff);
					}
				}
			}

			return ret;
		}

		static if(!deletedChar){
			MovedCharInfo deleteChar(string _account, string _char) @trusted{
				immutable charFile = getCharPath(_account, _char, deletedChar);
				enforceHTTP(charFile.exists && charFile.isFile, HTTPStatus.notFound,
					"Character '"~_char~"' not found");

				immutable deletedVault = getVaultPath(_account, true);
				if(!deletedVault.exists){
					mkdirRecurse(deletedVault);
				}

				string target;
				int index = 0;
				do{
					target = buildPath(deletedVault, _char~"-"~(index++).to!string~".bic");
				}while(target.exists);


				auto conn = api.mysqlConnPool.lockConnection();
				foreach(ref prep ; prepOnDelete){
					conn.exec(prep, _account, _char);
				}

				debug{
					import std.stdio : writeln;
					writeln("Renaming '",charFile,"' to '",target,"'");
				}
				charFile.rename(target);
				if((charFile~".meta").exists){
					(charFile~".meta").rename(target~".meta");
				}
				return MovedCharInfo(_account, baseName(target, ".bic"), true);
			}
		}

		static if(deletedChar){
			MovedCharInfo restoreChar(string _account, string _char) @trusted{
				import std.regex : matchFirst, ctRegex;

				immutable charFile = getCharPath(_account, _char, deletedChar);
				enforceHTTP(charFile.exists && charFile.isFile, HTTPStatus.notFound,
					"Character '"~_char~"' not found");

				immutable accountVault = getVaultPath(_account, false);
				immutable newName = _char.matchFirst(ctRegex!`^(.+?)-\d+$`)[1];

				immutable target = buildPath(accountVault, newName~".bic");
				enforceHTTP(!target.exists, HTTPStatus.conflict, "An active character has the same name.");


				auto conn = api.mysqlConnPool.lockConnection();
				foreach(ref prep ; prepOnActivate){
					conn.exec(prep, _account, _char);
				}

				debug{
					import std.stdio : writeln;
					writeln("Renaming '",charFile,"' to '",target,"'");
				}
				charFile.rename(target);
				if((charFile~".meta").exists){
					(charFile~".meta").rename(target~".meta");
				}

				return MovedCharInfo(_account, baseName(target, ".bic"), false);
			}
		}

		Metadata meta(string _account, string _char) const{
			Metadata metadata;

			immutable charPath = getCharPath(_account, _char, deletedChar);
			enforceHTTP(charPath.exists && charPath.isFile, HTTPStatus.notFound,
					"Character '"~_char~"' not found");

			immutable charMetaPath = charPath~".meta";
			if(charMetaPath.exists){
				metadata = charMetaPath
					.readText
					.deserializeJson!Metadata;
			}

			return metadata;
		}

		void meta(string _account, string _char, Metadata metadata){
			immutable charPath = getCharPath(_account, _char, deletedChar);
			enforceHTTP(charPath.exists && charPath.isFile, HTTPStatus.notFound,
					"Character '"~_char~"' not found");

			immutable charMetaPath = charPath~".meta";
			charMetaPath.writeFile(cast(immutable ubyte[])metadata.serializeToJsonString);
		}

	}


private:
	Api api;


	Character getChar(in string account, in string bicName, bool deleted){
		immutable path = getCharPath(account, bicName, deleted);
		enforceHTTP(path.exists && path.isFile, HTTPStatus.notFound, "Character '"~bicName~"' not found");
		return buildCharacter(account, DirEntry(path));
	}

	string getCharPath(in string accountName, in string bicFile, bool deleted) const{
		enforceHTTP(accountName.baseName == accountName, HTTPStatus.badRequest, "account name should not be a path");
		enforceHTTP(bicFile.baseName == bicFile, HTTPStatus.badRequest, "bic file name should not be a path");

		return buildNormalizedPath(getVaultPath(accountName, deleted), bicFile~".bic");
	}

	string getVaultPath(in string accountName, bool deleted) const{
		enforceHTTP(accountName.baseName == accountName, HTTPStatus.badRequest, "account name should not be a path");

		if(!deleted){
			return buildNormalizedPath(api.cfg["paths"]["servervault"].to!string, accountName);
		}
		else{
			immutable deletedVault = api.cfg["paths"]["servervault_deleted"].to!string;
			if(deletedVault.isAbsolute)
				return buildNormalizedPath(deletedVault, accountName);
			else
				return buildNormalizedPath(api.cfg["paths"]["servervault"].to!string, accountName, deletedVault);
		}

	}
	/// Converts a NWItemproperty into string identical to the property in-game description
	static Item gffToItem(in GffStruct gff){
		import nwn.nwscript.extensions;
		import nwn.types: NWItemproperty;
		const resolv = ResourceManager.get!StrRefResolver("resolver");
		const icons2DA = ResourceManager.fetchFile!TwoDA("nwn2_icons.2da");
		const props2DA = ResourceManager.fetchFile!TwoDA("itempropdef.2da");
		const costTable2DA = ResourceManager.fetchFile!TwoDA("iprp_costtable.2da");
		const paramTable2DA = ResourceManager.fetchFile!TwoDA("iprp_paramtable.2da");

		string toDescription(in NWItemproperty ip){

			string propName;
			string subType;
			string costValue;
			string paramValue;

			propName = resolv[props2DA.get("GameStrRef", ip.type, 0)];

			string subTypeTable = props2DA.get("SubTypeResRef", ip.type, "").toLower;
			if(subTypeTable != ""){
				int strref = ResourceManager.fetchFile!TwoDA(subTypeTable ~ ".2da").get("Name", ip.subType, 0);
				if(strref > 0)
					subType = resolv[strref];
			}
			string costValueTableId = props2DA.get("CostTableResRef", ip.type, "");
			if(costValueTableId != ""){
				string costValueTable = costTable2DA.get("Name", costValueTableId.to!int).toLower;
				int strref = ResourceManager.fetchFile!TwoDA(costValueTable ~ ".2da").get("Name", ip.costValue, 0);
				if(strref > 0)
					costValue = resolv[strref];
			}

			string paramTableId = props2DA.get("Param1ResRef", ip.type);
			if(paramTableId != ""){
				string paramTable = paramTable2DA.get("TableResRef", paramTableId.to!int).toLower;
				int strref = ResourceManager.fetchFile!TwoDA(paramTable ~ ".2da").get("Name", ip.p1, 0);
				if(strref > 0)
					paramValue = resolv[strref];
			}
			return propName
				~ (subType !is null ? " " ~ subType : null)
				~ (costValue !is null ? " " ~ costValue : null)
				~ (paramValue !is null ? " " ~ paramValue : null);
		}


		Item item;
		item.name = gff["LocalizedName"].get!GffLocString.resolve(resolv);
		item.type = gff["BaseItem"].get!GffInt;
		item.icon = icons2DA.get("icon", gff["Icon"].get!GffDWord);
		foreach(_, ipGff ; gff["PropertiesList"].get!GffList){
			item.properties ~= toDescription(ipGff.toNWItemproperty);
		}
		return item;
	}

}