fx_version 'cerulean'
games { 'rdr3' }
rdr3_warning 'I acknowledge that this is a prerelease build of RedM, and I am aware my resources *will* become incompatible once RedM ships.'
lua54 'yes'

author 'DJRLincs'
description 'Shared Map with Excalidraw - Collaborative map drawing tool for planning and notation'
version '1.0.0'

dependencies {
    'vorp_core',
    'oxmysql'
}

shared_scripts {
    'Config/config.lua'
}

client_scripts {
    'Client/client.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'Server/server.lua'
}

ui_page 'nui/index.html'

files {
    'nui/index.html',
    'nui/assets/*',
    'web/viewer.html',
    'tiles/Guarma/*.webp'
}
