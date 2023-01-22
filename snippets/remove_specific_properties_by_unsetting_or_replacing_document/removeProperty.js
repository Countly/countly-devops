//run on mongodb server as
//mongo < removeProperty.js

var COUNTLY = 'countly';
var props = ["clickid", "pubid", "subpubid", "udid", "ip"]; //meta array here
var rem = {};
var query = {_id:"SK_Appnext_2017:0"};
var collection = "campaigndata";

var conn = new Mongo(),
    db = conn.getDB(COUNTLY);

var doc = db[collection].findOne(query);

function formKey(prefix, prop){
    if(prefix && prefix.length)
        return prefix+"."+prop;
    return prop;
}

function isNumber(n) {
    return !isNaN(parseFloat(n)) && isFinite(n);
}

function findProps(doc, props, prefix){
    for(var key in doc){
        print("Checking "+formKey(prefix, key));
        for(var i = 0; i < props.length; i++){
            if(key == props[i]){
                rem[formKey(prefix, key)] = "";
                break;
            }
        }
        if(doc[key] && typeof doc[key] === "object" && (key === "d" || isNumber(key) || (key.indexOf("w") === 0 && isNumber(key.replace("w", ""))))){
            findProps(doc[key], props, key);
        }
    }
}
var start = new Date().getTime();
findProps(doc, props, "");
var end = new Date().getTime();

print(JSON.stringify(rem));

print('Execution time: ' + (end - start));

db[collection].update(query, {$unset:rem});