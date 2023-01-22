//run on mongodb server as
//mongo < replaceViewDataDocument.js

var COUNTLY = 'countly';
var props = "/ordersnproduct/app/open/";
var rem = {};
var query = {};
var collection = "app_viewdata597b4935afc606386459238a";

var conn = new Mongo(),
    db = conn.getDB(COUNTLY);
    db.auth("cemexdb", "16c8f34d370fe8ab81646c8bd5f074a56a5f4f9e");

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
        if(key.indexOf(props) === 0){
            delete doc[key];
            print("deleted");
        }
        if(doc[key] && typeof doc[key] === "object" && (key === "d" || isNumber(key) || (key.indexOf("w") === 0 && isNumber(key.replace("w", ""))))){
            findProps(doc[key], props, key);
        }
    }
}
var start = new Date().getTime();
db[collection].find(query).forEach(function(doc){
    findProps(doc, props, "");
    db[collection].update({_id:doc._id}, doc);
});
var end = new Date().getTime();

print('Execution time: ' + (end - start));