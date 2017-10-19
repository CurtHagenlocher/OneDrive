section OneDrive;

client_application = Expression.Evaluate(Text.FromBinary(Extension.Contents("client_application")));
scope = "wl.basic wl.skydrive wl.contacts_skydrive wl.offline_access";
windowWidth = 1200;
windowHeight = 1000;

TokenMethod = (code, grant_type) =>
    let
        Response = Web.Contents("https://login.live.com/oauth20_token.srf", [
            Content = Text.ToBinary(Uri.BuildQueryString([
                client_id = client_application[ClientId],
                client_secret = client_application[ClientSecret],
                grant_type = grant_type,
                code = code,
                refresh_token = code,
                redirect_uri = client_application[CallbackUrl]
            ])),
            Headers=[#"Content-type" = "application/x-www-form-urlencoded"]
        ]),
        Parts = Json.Document(Response)
    in
        Parts;

StartLogin = (resourceUrl, state, display) =>
    let
        AuthorizeUrl = "https://login.live.com/oauth20_authorize.srf?" & Uri.BuildQueryString([
            client_id = client_application[ClientId],
            scope = scope,
            response_type = "code",
            state = state,
            redirect_uri = client_application[CallbackUrl]])
    in
        [
            LoginUri = AuthorizeUrl,
            CallbackUri = client_application[CallbackUrl],
            WindowHeight = windowHeight,
            WindowWidth = windowWidth,
            Context = null
        ];

FinishLogin = (context, callbackUri, state) =>
    let
        Parts = Uri.Parts(callbackUri)[Query]
    in
        TokenMethod(Parts[code], "authorization_code");

Refresh = (resourceUrl, refresh_token) => TokenMethod(refresh_token, "refresh_token");

Table.GenerateByPage = (getNextPage as function) as table =>
    let
        listOfPages = List.Generate(
            () => getNextPage(null),
            (lastPage) => lastPage <> null,
            (lastPage) => getNextPage(lastPage)
        ),
        tableOfPages = Table.FromList(listOfPages, Splitter.SplitByNothing(), {"Column1"}),
        firstRow = tableOfPages{0}?
    in
        if (firstRow = null) then
            Table.FromRows({})
        else
            Value.ReplaceType(
                Table.ExpandTableColumn(tableOfPages, "Column1", Table.ColumnNames(firstRow[Column1])),
                Value.Type(firstRow[Column1])
            );

DirectoryColumns = {"id", "from", "name", "description", "parent_id", "size", "upload_location", "comments_count", "comments_enabled", "is_embeddable", "source", "link", "type", "shared_with", "created_time", "updated_time", "client_updated_time", "count"};

GetSharedStuff = () =>
    let
        source = Web.Contents("https://apis.live.net/v5.0/me/skydrive/shared"),
        json = Json.Document(source),
        data = json[data],
        table = Table.FromList(data, Splitter.SplitByNothing(), null, null, ExtraValues.Error),
        expanded = Table.ExpandRecordColumn(table, "Column1", DirectoryColumns)
    in
        expanded;

GetRoot = () =>
    let
        source = Web.Contents("https://apis.live.net/v5.0/me/skydrive"),
        json = Json.Document(source),
        id = json[id]
    in
        id;

GetOneDirectory = (path, id) =>
    let
        source = Web.Contents("https://apis.live.net/v5.0/" & id & "/files"),
        json = Json.Document(source),
        contents = json[data],
        table = if List.Count(contents) = 0 then #table({"Column1"}, {}) else Table.FromList(contents, Splitter.SplitByNothing(), null, null, ExtraValues.Error),
        expanded = Table.ExpandRecordColumn(table, "Column1", DirectoryColumns),
        buffered = Table.Buffer(expanded),
        withPath = Table.AddColumn(buffered, "path", each path & "/" & [name])
    in
        withPath;

GetDirectory = (path, id) => Table.GenerateByPage((previous) =>
    let
        dirlist = if previous = null then {} else Value.Metadata(previous)[dirs],
        nextdir = if previous = null then [path=path, id=id] else List.First(dirlist),
        directory = if nextdir = null then null else GetOneDirectory(nextdir[path], nextdir[id]),
        moredirs = if directory = null then {} else Table.ToRecords(Table.SelectRows(directory, each [count] > 0)),
        files = if directory = null then null else Table.SelectRows(directory, each [source] <> null),
        newlist = List.Skip(dirlist, 1) & moredirs
    in
        files meta [dirs=newlist]);

GetDirectoryAndFiles = () =>
    let
        files = GetDirectory("", GetRoot()),
        filtered = Table.SelectRows(files, each [id] <> null),
        withContent = Table.AddColumn(filtered, "Content", each Web.Contents([source])),
        reordered = Table.ReorderColumns(withContent,{"Content"} & DirectoryColumns),
        expanded = Table.ExpandRecordColumn(reordered, "from", {"name", "id"}, {"from.name", "from.id"}),
        changedType = Table.TransformColumnTypes(expanded,{{"size", Int64.Type}, {"comments_enabled", type logical}, {"comments_count", Int64.Type}, {"is_embeddable", type logical}, {"created_time", type datetimezone}, {"updated_time", type datetimezone}, {"client_updated_time", type datetimezone}, {"Content", type binary}})
    in
        changedType;

[DataSource.Kind = "OneDrive"]
shared OneDrive.Contents = () => GetDirectoryAndFiles();

OneDrive = [
    Authentication=[OAuth=[StartLogin=StartLogin, FinishLogin=FinishLogin, Refresh=Refresh]]
];
