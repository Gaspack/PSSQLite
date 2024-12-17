#handle PS2
if (-not $PSScriptRoot) {
    $PSScriptRoot = Split-Path $MyInvocation.MyCommand.Path -Parent
}



BeforeAll {
    $Verbose = @{}
    $PSVersion = $PSVersionTable.PSVersion.Major
    Import-Module $PSScriptRoot\..\PSSQLite -Force -verbose
    write-host $PSScriptRoot
    $SQLiteFile = "$PSScriptRoot\Working.SQLite"
    Remove-Item $SQLiteFile  -force -ErrorAction SilentlyContinue
    Copy-Item $PSScriptRoot\Names.SQLite $PSScriptRoot\Working.SQLite -force

    if ($env:APPVEYOR_REPO_BRANCH -and $env:APPVEYOR_REPO_BRANCH -notlike "master") {
        $Verbose.add("Verbose", $True)
    }
}


Describe "New-SQLiteConnection PS$PSVersion" {
    
    Context 'Strict mode' {



        Set-StrictMode -Version latest

        It 'should create a connection' {
            $global:Connection = New-SQLiteConnection @Verbose -DataSource :MEMORY:
            $global:Connection.ConnectionString | Should -be "Data Source=:MEMORY:;"
            $global:Connection.State | Should -be "Open"
        }
    }
}

Describe "Invoke-SQLiteQuery PS$PSVersion" {
    
    Context 'Strict mode' { 

        Set-StrictMode -Version latest

        It 'should take file input' {
            write-host $SQLiteFile
            $Out = @( Invoke-SqliteQuery @Verbose -DataSource $SQLiteFile -InputFile $PSScriptRoot\Test.SQL )
            $Out.count | Should -be 2
            $Out[1].OrderID | Should -be 500
        }

        It 'should take query input' {
            $Out = @( Invoke-SQLiteQuery @Verbose -Database $SQLiteFile -Query "PRAGMA table_info(NAMES)" -ErrorAction Stop )
            $Out.count | Should -Be 4
            $Out[0].Name | SHould -Be "fullname"
        }

        It 'should support parameterized queries' {
            
            $Out = @( Invoke-SQLiteQuery @Verbose -Database $SQLiteFile -Query "SELECT * FROM NAMES WHERE BirthDate >= @Date" -SqlParameters @{
                    Date = (Get-Date 3/13/2012)
                } -ErrorAction Stop )
            $Out.count | Should -Be 1
            $Out[0].fullname | Should -Be "Cookie Monster"

            $Out = @( Invoke-SQLiteQuery @Verbose -Database $SQLiteFile -Query "SELECT * FROM NAMES WHERE BirthDate >= @Date" -SqlParameters @{
                    Date = (Get-Date 3/15/2012)
                } -ErrorAction Stop )
            $Out.count | Should -Be 0
        }

        It 'should use existing SQLiteConnections' {
            Invoke-SqliteQuery @Verbose -SQLiteConnection $global:Connection -Query "CREATE TABLE OrdersToNames (OrderID INT PRIMARY KEY, fullname TEXT);"
            Invoke-SqliteQuery @Verbose -SQLiteConnection $global:Connection -Query "INSERT INTO OrdersToNames (OrderID, fullname) VALUES (1,'Cookie Monster');"
            @( Invoke-SqliteQuery @Verbose -SQLiteConnection $global:Connection -Query "SELECT name FROM sqlite_master WHERE type='table';" ) |
            Select -first 1 -ExpandProperty name |
            Should -be 'OrdersToNames'

            $global:COnnection.State | Should -Be Open

            $global:Connection.close()
        }

        It 'should respect PowerShell expectations for null' {
            
            #The SQL folks out there might be annoyed by this, but we want to treat DBNulls as null to allow expected PowerShell operator behavior.

            $Connection = New-SQLiteConnection -DataSource :MEMORY: 
            Invoke-SqliteQuery @Verbose -SQLiteConnection $Connection -Query "CREATE TABLE OrdersToNames (OrderID INT PRIMARY KEY, fullname TEXT);"
            Invoke-SqliteQuery @Verbose -SQLiteConnection $Connection -Query "INSERT INTO OrdersToNames (OrderID, fullname) VALUES (1,'Cookie Monster');"
            Invoke-SqliteQuery @Verbose -SQLiteConnection $Connection -Query "INSERT INTO OrdersToNames (OrderID) VALUES (2);"

            @( Invoke-SqliteQuery @Verbose -SQLiteConnection $Connection -Query "SELECT * FROM OrdersToNames" -As DataRow | Where { $_.fullname }).count |
            Should -Be 2

            @( Invoke-SqliteQuery @Verbose -SQLiteConnection $Connection -Query "SELECT * FROM OrdersToNames" | Where { $_.fullname } ).count |
            Should -Be 1
        }
        It "should insert and verify JSON data in the database" {
            $Connection = New-SQLiteConnection -DataSource :MEMORY: 
            # Insert JSON data into the database
            $jsonData = '{"name": "John Doe", "age": 30, "city": "New York"}'
            Invoke-SqliteQuery -SQLiteConnection $Connection -Query "CREATE TABLE IF NOT EXISTS JsonData (id INTEGER PRIMARY KEY, data TEXT);"
            Invoke-SqliteQuery -SQLiteConnection $Connection -Query "INSERT INTO JsonData (data) VALUES ('$jsonData');"
    
            # Query the JSON data from the database
            $name = Invoke-SqliteQuery -SQLiteConnection $Connection -Query "SELECT json_extract(data, '$.name') AS name FROM JsonData WHERE id = 1;" -As DataTable
            $age = Invoke-SqliteQuery -SQLiteConnection $Connection -Query "SELECT json_extract(data, '$.age') AS age FROM JsonData WHERE id = 1;" -As DataTable
            $city = Invoke-SqliteQuery -SQLiteConnection $Connection -Query "SELECT json_extract(data, '$.city') AS city FROM JsonData WHERE id = 1;" -As DataTable
    
            # Verify the extracted JSON data
            $name[0].name | Should -Be "John Doe"
            $age[0].age | Should -Be 30
            $city[0].city | Should -Be "New York"
        }
    }
}

Describe "Out-DataTable PS$PSVersion" {

    Context 'Strict mode' { 

        Set-StrictMode -Version latest

        It 'should create a DataTable' {
            
            $Script:DataTable = 1..1000 | % {
                New-Object -TypeName PSObject -property @{
                    fullname  = "Name $_"
                    surname   = "Name"
                    givenname = "$_"
                    BirthDate = (Get-Date).Adddays(-$_)
                } | Select fullname, surname, givenname, birthdate
            } | Out-DataTable #@Verbose

            $Script:DataTable.GetType().Fullname | Should -Be 'System.Data.DataTable'
            @($Script:DataTable.Rows).Count | Should -Be 1000
            $Columns = $Script:DataTable.Columns | Select -ExpandProperty ColumnName
            $Columns[0] | Should -Be 'fullname'
            $Columns[3] | Should -Be 'BirthDate'
            $Script:DataTable.columns[3].datatype.fullname | Should -Be 'System.DateTime'
            
        }
    }
}

Describe "Invoke-SQLiteBulkCopy PS$PSVersion" {

    Context 'Strict mode' { 

        Set-StrictMode -Version latest

        It 'should insert data' {
            Invoke-SQLiteBulkCopy @Verbose -DataTable $Script:DataTable -DataSource $SQLiteFile -Table Names -NotifyAfter 100 -force
            
            @( Invoke-SQLiteQuery @Verbose -Database $SQLiteFile -Query "SELECT fullname FROM NAMES WHERE surname = 'Name'" ).count | Should -Be 1000
        }
        It "should adhere to ConflictCause" {
            
            #Basic set of tests, need more...

            #Try adding same data
            { Invoke-SQLiteBulkCopy @Verbose -DataTable $Script:DataTable -DataSource $SQLiteFile -Table Names -NotifyAfter 100 -force } | Should -Throw
            
            #Change a known row's prop we can test to ensure it does or does not change
            $Script:DataTable.Rows[0].surname = "Name 1"
            { Invoke-SQLiteBulkCopy @Verbose -DataTable $Script:DataTable -DataSource $SQLiteFile -Table Names -NotifyAfter 100 -force } | Should -Throw

            $Result = @( Invoke-SQLiteQuery @Verbose -Database $SQLiteFile -Query "SELECT surname FROM NAMES WHERE fullname = 'Name 1'")
            $Result[0].surname | Should -Be 'Name'

            { Invoke-SQLiteBulkCopy @Verbose -DataTable $Script:DataTable -DataSource $SQLiteFile -Table Names -NotifyAfter 100 -ConflictClause Rollback -Force } | Should -Throw
            
            $Result = @( Invoke-SQLiteQuery @Verbose -Database $SQLiteFile -Query "SELECT surname FROM NAMES WHERE fullname = 'Name 1'")
            $Result[0].surname | Should -Be 'Name'

            Invoke-SQLiteBulkCopy @Verbose -DataTable $Script:DataTable -DataSource $SQLiteFile -Table Names -NotifyAfter 100 -ConflictClause Replace -Force

            $Result = @( Invoke-SQLiteQuery @Verbose -Database $SQLiteFile -Query "SELECT surname FROM NAMES WHERE fullname = 'Name 1'")
            $Result[0].surname | Should -Be 'Name 1'


        }
    }
}



AfterAll {
    Remove-Item $SQLiteFile -force -ErrorAction SilentlyContinue
}