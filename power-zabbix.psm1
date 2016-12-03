#M�dulo para o powershell!


#Verifica se um assembly j� foi carregado!
Function CheckAssembly {
	param($Name)
	
	if($Global:PowerZabbix_Loaded){
		return $true;
	}
	
	if( [appdomain]::currentdomain.getassemblies() | ? {$_ -match $Name}){
		$Global:PowerZabbix_Loaded = $true
		return $true;
	} else {
		return $false
	}
}

Function LoadJsonEngine {

	$Engine = "System.Web.Extensions"

	if(!(CheckAssembly Engine)){
		try {
			Add-Type -Assembly  $Engine
			$Global:PowerZabbix_Loaded = $true;
		} catch {
			throw "ERROR_LOADIING_WEB_EXTENSIONS: $_";
		}
	}

}

Function ConvertToJson($o) {
	LoadJsonEngine

	$jo=new-object system.web.script.serialization.javascriptSerializer
    return $jo.Serialize($o)
}

Function ConvertFromJson([string]$json) {
	LoadJsonEngine
	$jo=new-object system.web.script.serialization.javascriptSerializer
    return $jo.DeserializeObject($json)
}


#Faz uma chamada para a API do zabbix!
Function CallZabbixURL([object]$data = $null,$url = $null,$method = "POST", $contentType = "application/json-rpc"){
	$ErrorActionPreference="Stop";
	
	write-verbose "URL param is: $Url";
	
	
	try {
		if($data -is [hashtable]){
			$data = ConvertToJson $data;
		}
		
		if($Global:PowerZabbix_ZabbixUrl -and !$url){
			$url = $Global:PowerZabbix_ZabbixUrl;
		}
		
		if($url -NotLike "*api_jsonrpc.php" ){
			if($url -NotLike "*/"){
				$url += "/"
			}
			
			$url += "api_jsonrpc.php"
		}
		

		write-verbose "CallZabbixURL: Creating WebRequest method... Url: $url. Method: $Method ContentType: $ContentType";
		$Web = [System.Net.WebRequest]::Create($url);
		$Web.Method = $method;
		$Web.ContentType = $contentType
		
		#Determina a quantidade de bytes...
		[Byte[]]$bytes = [byte[]][char[]]$data;
		
		#Escrevendo os dados
		$Web.ContentLength = $bytes.Length;
		write-verbose "CallZabbixURL: Bytes lengths: $($Web.ContentLength)"
		
		
		write-verbose "CallZabbixURL: Getting request stream...."
		$RequestStream = $Web.GetRequestStream();
		$RequestStream.Write($bytes, 0, $bytes.length);
		
		
		write-verbose "CallZabbixURL: Making http request... Waiting for the response..."
		$HttpResp = $Web.GetResponse();
		
		$responseString  = $null;
		
		if($HttpResp){
			write-verbose "CallZabbixURL: Getting response stream..."
			$ResponseStream  = $HttpResp.GetResponseStream();
			
			$IO = New-Object System.IO.StreamReader($ResponseStream);
			
			write-verbose "CallZabbixURL: Reading response stream...."
			$responseString = $IO.ReadToEnd();
		}
		
		return $responseString;
	} catch {
		throw "ERROR_CALLING_ZABBIX_URL: $_";
	} finally {
		if($IO){
			$IO.close()
		}
		
		if($ResponseStream){
			$ResponseStream.Close()
		}
		
		<#
		if($HttpResp){
			write-host "Finazling http request stream..."
			$HttpResp.finalize()
		}
		#>

	
		if($RequestStream){
			write-verbose "Finazling request stream..."
			$RequestStream.Close()
		}
	}
}


#Trata a resposta enviada pela API do zabbix.
#Em caso de erros, uma expcetion ser� tratada. Caso contr�rio, um objeto contendo a resposta ser� retornado.
Function TranslateZabbixJson {
	param($ZabbixResponse)
	
	#Cria um objeto contendo os campos da resposta!
	$ZabbixResponseO = ConvertFromJson $ZabbixResponse;
	
	#Se o campo "error" estiver presente, significa que houve um erro!
	#https://www.zabbix.com/documentation/3.0/manual/api
	if($ZabbixResponseO.error){
		$ZabbixError = $ZabbixResponseO.error;
		$MessageException = "[$($ZabbixError.code)]: $($ZabbixError.data). Details: $($ZabbixError.data)";
		$Exception = New-Object System.Exception($MessageException)
		$Exception.Source = "ZabbixAPI"
		throw $Exception;
		return;
	}
	
	
	#Caso contr�rio, o resultado ser� enviado
	return $ZabbixResponseO.result;
}


#Guarda as informa��es de conex�o com o Zabbix na mem�ria da sess�o para uso com os outros comandos!
Function Set-ZabbixConnection($url, $user, $password) {
	$Global:PowerZabbix_ZabbixUrl 		= $url
	$Global:PowerZabbix_ZabbixUser 		= $user
	$Global:PowerZabbix_ZabbixPassword 	= $password
}

#Gera um id para as requisi��es da api DO ZABBIX
Function  GetNewZabbixApiId {
	return [System.Guid]::NewGuid().Guid.ToString()
}

#Autentica no Zabbix. As informa��es de autentica��o ser�o guardadas na sessao para autentica��o posterior!
Function Auth-Zabbix {
	[CmdLetBinding()]
	param(
			 $User 		= $null
			,$Password	= $null
			,$URL 		= $null
			,[switch]$Save = $null
		)

	
	#Se o usu�rio n�o foi informado, ent�o tenta obter do cache!
	if(!$User){
		$User 		= $Global:PowerZabbix_ZabbixUser
		$Password 	= $Global:PowerZabbix_ZabbixPassword
		
		#Se ainda continuar sem usu�rio, pergunta para o usu�rio!
		if(!$User){
			$Creds = Get-Credential
			$NC = $Creds.GetNetworkCredential();
			$User = $NC.UserName
			$Password = $NC.Password;
		}
	}
	
	if(!$URL){
		if($Global:PowerZabbix_ZabbixUrl){
			$URL = $Global:PowerZabbix_ZabbixUrl
		} else {
			$URL = Read-Host "Forne�a a URL para o zabbix"
		}
	}
	
	write-verbose "Auth-Zabbix: URL is: $URL"
	
	#Salva o usu�rio...
	if($Save){
		 $Global:PowerZabbix_ZabbixUser = $User;
		 $Global:PowerZabbix_ZabbixPassword = $Password;
		 $Global:PowerZabbix_ZabbixUrl = $URL;
	}
		
		
	#Monta o objeto de autentica��o
	[string]$NewId = GetNewZabbixApiId;
	$AuthString = ConvertToJson @{
							jsonrpc = "2.0"
							method	= "user.login"
							params =  @{
										user 		= $User
										password	= $Password
									}
							id = $NewId
							auth = $null
						}
						
	#Chama a Url
	$resp = CallZabbixURL -data $AuthString -url $URL;
	$resultado = TranslateZabbixJson $resp;

	if($resultado){
		$Global:PowerZabbix_Auth = $resultado;
		return;
	}
}

#Obt�m o token de autentica��o se existe. Caso contr�rio, chama a fun��o de auth!
Function GetZabbixApiAuthToken {
	if( $Global:PowerZabbix_Auth -and $Global:PowerZabbix_ZabbixUrl ){
		return $Global:PowerZabbix_Auth;
	} else {
		Auth-Zabbix -Save;
		
		if(!$Global:PowerZabbix_Auth){
			throw 'INVALID_AUTH_TOKEN'
			return;
		}
		
		return $Global:PowerZabbix_Auth;
	}
}


#Retorna uma hashtable para ser usada na comunica��o com a apu
Function ZabbixAPI_NewParams {
	param($method)
	
	[string]$token = GetZabbixApiAuthToken;
	[string]$NewId = GetNewZabbixApiId;
	
	
	$APIParams =  @{
					jsonrpc = "2.0"
					auth 	= $token
					id 		= $NewId
					method	= $method
					params 	=  @{}
				}
				
	return $APIParams
}


#Fun��o gen�rica usada para chamar o m�todo get de diversos elementos!
#Retorna uma hashtable contendo as informa��es baseadas no filtro!
#Assim, os usu�rios da mesma podem fazer altera��es se necess�rio!!!
#APIParams @{common=@{};props=@{}}
Function ZabbixAPI_Get {
	param(
		[hashtable]$Options
		,$APIParams = @{}
	)
	
	#Determinando searchByAny
	if($APIParams.common.searchByAny){
		$Options.params.add("searchByAny", $true);
	}
	
	if($APIParams.common.startSearch){
		$Options.params.add("startSearch", $true);
	}
	
	
	if($APIParams.common.limit){
		$Options.params.add("limit", $APIParams.common.limit);
	}
	
	
	if($APIParams.common.output){
		$Options.params.add("output", $APIParams.common.output);
	}
	
				
	#Determinando se iremos usar search ou filter pra buscar...
	if($APIParams.common.search){
		$Options.params.add("searchWildcardsEnabled",$true);
		$Options.params.add("search",@{
									name = $APIParams.props.name
							});
	} 
	elseif($APIParams.props.name) {
		$Options.params.add("filter",@{
									name = $APIParams.props.name
							});
	}
	
	return;
}

#Converte uma lista de valores para ids!
Function ZabbixAPI_List2Ids {
	param($SourceList, [scriptblock]$NamesToId)

	$Ids = @();
	$Names = @();
	
	$SourceList | %{
		if($_ -as [int]){
			$Ids += [int]$_;
		} else {
			$Names += $_.toString()
		}
	}
	
	if($Names){
		$Ids += & $NamesToId $Names;
	}
	
	return $Ids;
}

#Converte um datetime para um unixtimestamp!
Function Datetime2Unix {
	param([datetime]$Datetime)
	
	return $Datetime.toUniversalTime().Subtract([datetime]'1970-01-01').totalSeconds;
}

Function UnixTime2LocalTime {
	param([uint32]$unixts)
	
	return ([datetime]'1970-01-01').toUniversalTime().addSeconds($unixts).toLocalTime();
}

############# Aux cmdlets ###############
#######Cmdlets auxiliares que podem ser usados para facilitar a intera��o com a API, mas que n�o s�o implementa��es da mesma!################
	
	#Retorna uma hashtable com as configura��es para a interface a ser usada com o cmdlet Create-ZabbixHost
	#Para mais informa��es verifique o link https://www.zabbix.com/documentation/3.4/manual/api/reference/hostinterface/object
	Function Get-InterfaceConfig {
		param(
			#Pode ser um nome DNS ou IP. O que vai determinar o tipo � a presen�a ou n�o do par�metro -IsIP
			$Address = $null
			
			,#Porta da interface. 
				[int]$Port = 10050
				
			,#Indica que a interface n�o � a padr�o!
			 #Neste caso, a propriedade main ser� marcada como 0.
				[switch]$NoMain 	= $false

			,#Indica se o valor em Address � um IP. Se sim, a interface ser� configurada como IP.
				[switch]$IsIP		= $False
			
			
			,#Tipo da interface. Pode se usar o nome ou id. Verifique o link para os ids!
				[ValidateSet("Agent","SNMP","IPMI","JMX",1,2,3,4)]
				$Type = "Agent"
		)
		
		$Config = @{dns="";ip="";main=1;port=$Port;type=[int]$null;useip=1};
		
		#Transforma o tipo em n�mero!
		if($Type -is [string]){
			$i = 1;
			$Type = @("Agent","SNMP","IPMI","JMX") |  ? { if($Type -eq $_){return $true} else {$i++;return $false} } | %{$i};
		}
		
		$Config.type = $Type;
		
		
		if($IsIP){
			$Config.ip = [string]$Address;
		} else {
			$Config.dns = [string]$Address;
			$Config.useip = 0;
		}
		
		if($NoMain){
			$Config.main = 0;
		}
		
		
		return $Config;
		
	}

	
	
############# API cmdlets ###############
#######API implementations. A partir daqui, segue as implementa��es da API################

######### HOST
	#Equivalente ao m�todo da API host.get
	#https://www.zabbix.com/documentation/3.4/manual/api/reference/host/get
	Function Get-ZabbixHost {
		[CmdLetBinding()]
		param(
			$Name = @()
			,[switch]$Search 	   = $false
			,[switch]$SearchByAny  = $false
			,[switch]$StartSearch  = $false
			,$output				= $null
		)

				
		#Determinando searchByAny
		$APIParams = ZabbixAPI_NewParams "host.get"
		ZabbixAPI_Get $APIParams -APIParams @{
					common = @{
							search 		= $Search 
							searchByAny = $SearchByAny
							startSearch = $StartSearch
							output		= $output
						}
						
					props = @{
						name = $Name 
					}
				}		
		$APIString = ConvertToJson $APIParams;
							
		#Chama a Url
		$resp = CallZabbixURL -data $APIString;
		$resultado = TranslateZabbixJson $resp;
		
		
		$ResultsObjects = @();
		if($resultado){
			$resultado | %{
				$ResultsObjects += NEw-Object PSObject -Prop $_;	
			}
		}

		return $ResultsObjects;
	}


	#Equivalente ao m�todo da API host.create
	#https://www.zabbix.com/documentation/3.4/manual/api/reference/hostgroup/create
	Function Create-ZabbixHost {
		[CmdLetBinding()]
		param(
			$HostName
			,$VisibleName = $null
			,$Interfaces
			,$Groups = $null
			,$Templates = $null
		)

		
		$APIPArams = ZabbixAPI_NewParams "host.create";
		
		$APIPArams.params.add("host",$HostName);
		
		if($VisibleName){
			$APIPArams.params.add("name",$VisibleName);
		}
		
		$APIParams.params.add("interfaces",$interfaces);
		
		$AllGroups = @();
		if($Groups)	{
			$Groups | %{
				$AllGroups += @{groupid=$_.groupid};
			}
			$APIParams.params.add("groups", $AllGroups );
		}

		
		$AllTemplates = @();
		if($Templates){
			$Templates | %{
				$AllTemplates += @{templateid=$_.templateid};
			}
			$APIParams.params.add("templates", $AllTemplates );
		}
		
		
		$APIString = ConvertToJson $APIParams;
							
		#Chama a Url
		$resp = CallZabbixURL -data $APIString;
		$resultado = TranslateZabbixJson $resp;
		
		
		$ResultsObjects = @();
		if($resultado){
			$resultado | %{
				$ResultsObjects += NEw-Object PSObject -Prop $_;	
			}
		}

		return $ResultsObjects;
	}


######### HOSTGROUP	
	#Equivalente ao m�todo da API hostgroup.get
	#https://www.zabbix.com/documentation/3.4/manual/api/reference/hostgroup/get
	Function Get-ZabbixHostGroup {
		[CmdLetBinding()]
		param(
			[string[]]$Name = @()
			,[switch]$Search 	   = $false
			,[switch]$SearchByAny  = $false
			,[switch]$StartSearch  = $false
			,$Output			   = $null
		)

				
		#Determinando searchByAny
		$APIParams = ZabbixAPI_NewParams "hostgroup.get"
		ZabbixAPI_Get $APIParams -APIParams @{
					common = @{
							search 		= $Search 
							searchByAny = $SearchByAny
							startSearch = $StartSearch
							output		= $output
						}
						
					props = @{
						name = $Name 
					}
				}
		
		write-verbose "Get-ZabbixHostGroup: APIParams, before convert $APIParams"
		$APIString = ConvertToJson $APIParams;
		write-verbose "Get-ZabbixHostGroup: APIString, before convert $APISTring"
							
		#Chama a Url
		write-verbose "Get-ZabbixHostGroup:  calling zabbix url function..."
		$resp = CallZabbixURL -data $APIString;
		write-verbose "Get-ZabbixHostGroup:  response received! Calling translate..."
		$resultado = TranslateZabbixJson $resp;
		write-verbose "Get-ZabbixHostGroup:  Translated!"
		
		write-verbose "Get-ZabbixHostGroup: Building result objexts..."
		$ResultsObjects = @();
		if($resultado){
			$resultado | %{
				$ResultsObjects += NEw-Object PSObject -Prop $_;	
			}
		}

		return $ResultsObjects;
	}

	#Equivalente ao m�todo da API hosgroup.create
	#https://www.zabbix.com/documentation/3.4/manual/api/reference/hostgroup/create
	Function Create-ZabbixHostGroup {
		[CmdLetBinding()]
		param(
			[string[]]$Name
		)

		
		$APIPArams = ZabbixAPI_NewParams "hostgroup.create";
		
		$AllHostGroups = @();
		
		$Name | %{
			$AllHostGroups += @{name = [string]$_};
		}
		
		$APIParams.params = $AllHostGroups;
		
		
		$APIString = ConvertToJson $APIParams;
		write-verbose "Create-ZabbixHostGroup: APIString: $APIString"
							
		#Chama a Url
		$resp = CallZabbixURL -data $APIString;
		$resultado = TranslateZabbixJson $resp;
		
		
		$ResultsObjects = @();
		if($resultado){
			$resultado | %{
				$ResultsObjects += NEw-Object PSObject -Prop $_;	
			}
		}

		return $ResultsObjects;
	}

	
######### TEMPLATE
	#Equivalente ao m�todo da API template.get
	#https://www.zabbix.com/documentation/3.4/manual/api/reference/template/get
	Function Get-ZabbixTemplate {
		[CmdLetBinding()]
		param(
			$Name = @()
			,[switch]$Search 	   = $false
			,[switch]$SearchByAny  = $false
			,[switch]$StartSearch  = $false
		)

				
		#Determinando searchByAny
		$APIParams = ZabbixAPI_NewParams "template.get"
		ZabbixAPI_Get $APIParams -APIParams @{
					common = @{
							search 		= $Search 
							searchByAny = $SearchByAny
							startSearch = $StartSearch
						}
						
					props = @{
						name = $Name 
					}
				}		
		$APIString = ConvertToJson $APIParams;
							
		#Chama a Url
		$resp = CallZabbixURL -data $APIString;
		$resultado = TranslateZabbixJson $resp;
		
		
		$ResultsObjects = @();
		if($resultado){
			$resultado | %{
				$ResultsObjects += NEw-Object PSObject -Prop $_;	
			}
		}

		return $ResultsObjects;
	}


######### EVENT
	#Equivalente ao m�todo da API event.get
	#https://www.zabbix.com/documentation/3.4/manual/api/reference/event/get
	Function Get-ZabbixEvent {
		[CmdLetBinding()]
		param(
			$Hosts 	= @()		
			,$Groups  = @()
			,$TimeFrom 	= $null
			,$TimeTill	= $null
			
			,
				[ValidateSet("trigger","discovered host","discovered service","auto-registered host","item","LLD rule",0,1,2,3,4,5)]
				$Object				= $null
				
			,$Value					= '1' #PROBLEM
			,$selectHosts 			= $null
			,$selectRelatedObject	= $null
			,	
				[Alias("selectAcks")]
				$selectAcknowledges	= $null
				
			,$limit					= $null
		)

				
		#Determinando searchByAny
		[hashtable]$APIParams = ZabbixAPI_NewParams "event.get"
		ZabbixAPI_Get $APIParams -APIParams @{
					common = @{
							search 		= $false 
							searchByAny = $false
							startSearch = $false
							limit		= $limit
						}
				}
				
		if($TimeFrom){
			$APIParams.params.add("time_from", [string](Datetime2Unix $TimeFrom) ); 
		}
		
		if($TimeTill){
			$APIParams.params.add("time_till", [string](Datetime2Unix $TimeTill) ); 
		}
		
		if($Hosts){
			write-verbose "Get-ZabbixEvent: Castings groups to hosts ids..."
			[int[]]$HostIds = ZabbixAPI_List2Ids $Hosts { param($HostNames) Get-ZabbixHost -Name $HostNames -output @('hostid') | %{$_.hostid}};
			$APIParams.params.add("hostids", $HostsIds);
			write-verbose "Get-ZabbixEvent: Hosts add casted sucessfully!"
		}
		
		if($Groups){
			write-verbose "Get-ZabbixEvent: Castings groups to groups ids..."
			[int[]]$GroupIds = ZabbixAPI_List2Ids $Groups { param($GroupNames) Get-ZabbixHostGroup -Name $GroupNames -Output @('groupid') | %{$_.groupid} };
			$APIParams.params.add("groupids", $GroupIds);
			write-verbose "Get-ZabbixEvent: Groups add casted sucessfully!"
		}
		
		if($selectAcknowledges){
			$APIParams.params.add("select_acknowledges", $selectAcknowledges);
		}
		
		
		if($Object){
			if($Object -is [string]){
				$i = 0;
				
				$Object = 'trigger','discovered host','discovered service','auto-registered host','item','LLD rule' | ?{
					if($_ -eq $Object){
						return $true;
					} else {
						$i++;return $false;
					}
				} | %{$i}
			}
		
			$APIParams.params.add("object", $object )
		}
		
		if($selectHosts){
			$APIParams.params.add("selectHosts", $selectHosts);
		}
		
		if($selectRelatedObject){
			$APIParams.params.add("selectRelatedObject", $selectRelatedObject);
		}
				
		write-verbose "Get-ZabbixEvent: About to generate json from apiparams!"
		$APIString = ConvertToJson $APIParams;
		write-verbose "JSON is: $APIString";
		
		#Chama a Url
		$resp = CallZabbixURL -data $APIString;
		$resultado = TranslateZabbixJson $resp;
		
		
		$ResultsObjects = @();
		if($resultado){
			$resultado | %{
				$r = NEw-Object PSObject -Prop $_;
				
				#Adiciona o datetime local...
				if($r | gm "clock"){
					$r | Add-Member -Type Noteproperty -Name "datetime" -Value (UnixTime2LocalTime $r.clock)
				}
				
				$ResultsObjects += $r;
			}
		}

		return $ResultsObjects;
	}


	
	