# Arco Linux BR 🇧🇷

**Arco Linux BR** é um projeto baseado no Arch Linux com uma proposta simples: transformar uma instalação tradicional do Arch em uma experiência **instalar, conectar e usar**.

A inspiração vem de projetos como **Kurumin** e **Knoppix**, que buscaram tornar o Linux acessível e funcional imediatamente após a instalação. O Arco Linux BR leva essa filosofia para o Arch Linux, preservando sua base moderna e rolling release, mas automatizando a configuração necessária para que o sistema esteja pronto para uso.

## 🎯 Objetivo

O objetivo do projeto é criar um Arch Linux que consiga reconhecer o ambiente onde está sendo executado e configurar automaticamente o que for necessário.

O sistema deve funcionar tanto em:

* 🖥️ computadores físicos;
* 💻 notebooks;
* 🖧 servidores;
* 🧪 máquinas virtuais;
* ☁️ ambientes virtualizados.

A ideia é reduzir ao mínimo a necessidade de configuração manual após a instalação.

## 🌐 Rede que se recupera sozinha

Um dos componentes centrais do projeto é o **Arco Network Guard**.

Ele diagnostica a rede durante o boot e verifica:

* interfaces disponíveis;
* Ethernet;
* Wi-Fi;
* endereço IP;
* gateway;
* DHCP;
* DNS;
* acesso à Internet;
* conflitos entre configurações;
* NetworkManager;
* configurações de redes virtuais.

O princípio é simples:

> **Se a rede estiver funcionando, não mexa nela. Se estiver quebrada, tente recuperá-la.**

O sistema utiliza uma estratégia progressiva de recuperação antes de reconstruir completamente a configuração.

Isso permite que o mesmo sistema seja transferido entre diferentes máquinas físicas ou ambientes virtuais com o mínimo possível de intervenção manual.

## 🖥️ Desktop

O projeto utiliza o **GNOME** como ambiente desktop principal e busca oferecer uma experiência pronta para uso, incluindo:

* áudio;
* Bluetooth;
* impressão;
* armazenamento externo;
* compartilhamento de arquivos;
* fontes;
* codecs e componentes necessários;
* integração com hardware.

## 🧑‍💻 Hardware e virtualização

O Arco Linux BR procura detectar automaticamente o ambiente de execução.

Em máquinas virtuais, a configuração inclui suporte para tecnologias como:

* QEMU;
* KVM;
* libvirt;
* GNOME Boxes;
* SPICE;
* VirtIO;
* QEMU Guest Agent;
* SPICE Agent.

O objetivo é que uma instalação do Arco possa funcionar adequadamente tanto em uma máquina física quanto em uma VM sem exigir uma versão diferente do sistema.

## 🔤 Fontes

O projeto também busca fornecer uma experiência adequada para documentos e aplicações comuns, incluindo:

* Noto;
* Liberation;
* fontes compatíveis com Microsoft;
* emojis;
* fontes CJK quando necessárias.

Quando determinado pacote não está disponível nos repositórios oficiais do Arch, o projeto pode utilizar mecanismos alternativos, como o AUR, respeitando a natureza do Arch Linux.

## 🔐 Segurança

O projeto procura automatizar a configuração sem simplesmente desabilitar mecanismos de segurança.

Componentes como:

* polkit;
* GNOME Keyring;
* NetworkManager;
* firewall;

são configurados preservando suas funções.

A automação deve resolver problemas de usabilidade sem transformar o sistema em uma configuração insegura.

## 🏗️ Filosofia

O Arco Linux BR não pretende substituir o Arch Linux.

A proposta é construir uma camada de automação sobre o Arch para quem deseja:

**Arch Linux + configuração automática + desktop pronto + recuperação inteligente.**

Em vez de perguntar ao usuário:

> "Como você quer configurar seu sistema?"

a ideia é que o sistema primeiro pergunte:

> "O que este computador precisa?"

e então faça a configuração apropriada.

## 🚧 Estado do projeto

O projeto está em desenvolvimento.

As primeiras versões estão concentradas em:

* recuperação automática de rede;
* detecção de hardware;
* suporte a máquinas virtuais;
* configuração do GNOME;
* fontes;
* áudio;
* Bluetooth;
* virtualização;
* automação pós-instalação;
* recuperação automática durante o boot.

Novos componentes serão adicionados progressivamente.

## 🇧🇷 Arco Linux BR

Um Arch Linux pensado para **instalar, conectar, configurar e usar**.

**Menos configuração manual.
Mais automação.
Mais Arch.**
