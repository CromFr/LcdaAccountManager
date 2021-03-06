module utils;
import std.path;
import std.file;
import std.string: toUpper;


/// Builds a path like a case insensitive filesystem.
/// basePath is assumed to have the correct case.
/// If a subfile exists, fixes the case. If does not exist, append the name as is.
string buildPathCI(T...)(in string basePath, T subFiles){
	assert(basePath.exists, "basePath does not exist");
	string path = basePath;

	foreach(subFile ; subFiles){
		//Case is correct, cool !
		if(buildPath(path, subFile).exists){
			path = buildPath(path, subFile);
		}
		//Most likely only the extension is fucked up
		else if(buildPath(path, subFile.stripExtension ~ subFile.extension.toUpper).exists){
			path = buildPath(path, subFile.stripExtension ~ subFile.extension.toUpper);
		}
		//Perform full scan of the directory
		else{
			foreach(file ; path.dirEntries(SpanMode.shallow)){
				if(filenameCmp!(CaseSensitive.no)(file.baseName, subFile) == 0){
					path = file.name;
					break;
				}
			}
		}
	}
	return path;
}